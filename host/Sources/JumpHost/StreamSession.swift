import Foundation
import WebRTC

struct DeviceInfo {
    let name: String
    /// Client viewport in physical pixels.
    let width: Int
    let height: Int
    let scale: Double
    /// The client draws the cursor itself (`{"cursor":true}` in auth), so leave it out of the video.
    let drawsCursor: Bool
    /// Video codecs the client can receive, e.g. "video/H265" (empty for older clients).
    let codecs: [String]
    /// Why the client is connecting again, when it is an automatic reconnect (for the log).
    let reconnect: String?
    var receivesHEVC: Bool { codecs.contains { $0.uppercased() == "VIDEO/H265" } }

    init(_ raw: Any?) {
        let dict = raw as? [String: Any] ?? [:]
        name = (dict["name"] as? String) ?? "Unknown device"
        width = (dict["width"] as? NSNumber)?.intValue ?? 0
        height = (dict["height"] as? NSNumber)?.intValue ?? 0
        scale = (dict["scale"] as? NSNumber)?.doubleValue ?? 1
        drawsCursor = (dict["cursor"] as? Bool) ?? false
        codecs = (dict["codecs"] as? [String]) ?? []
        reconnect = dict["reconnect"] as? String
    }
}

/// One streaming session: WebRTC peer connection + screen capture + input channel.
/// All mutable state lives on `queue`, except the injector, which runs on its own input queue.
final class StreamSession: NSObject {
    enum Event {
        case connected
        /// The client turned its own audio playback on or off.
        case clientAudio(on: Bool)
        /// The client asks to change the host password; answer with `reply`.
        case passwordChange(current: String, new: String)
        case ended(reason: String?)
    }

    static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        RTCSetMinDebugLogLevel(.warning)
        return RTCPeerConnectionFactory(encoderFactory: HighLevelH264EncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    let signaling: SignalingChannel
    let device: DeviceInfo
    var onEvent: ((Event) -> Void)?

    private let queue: DispatchQueue
    private let injector = InputInjector()
    private var peerConnection: RTCPeerConnection?
    private var capturer: ScreenCapturer?
    private var videoSource: RTCVideoSource?
    private var displayID: CGDirectDisplayID?
    private let clipboard = ClipboardSync()
    private var inputChannel: RTCDataChannel?
    private var audioChannel: RTCDataChannel?
    private var displayMessage: [String: Any]?
    private var remoteDescriptionSet = false
    private var pendingCandidates: [RTCIceCandidate] = []
    private var stopped = false
    /// Being ended by the host (the viewer is told first): nothing restarts any more.
    private var finishing = false
    private var captureRestarts = 0
    private let cursorTracker = CursorTracker()
    /// Latest cursor shape, re-sent whenever the input channel (re)opens.
    private var cursorImageMessage: [String: Any]?
    private var statsTimer: DispatchSourceTimer?
    private var lastBytesSent: Double = 0
    private var lastStatsTime: CFTimeInterval = 0
    /// Everything sent on the connection (video, sound, input replies) and the part that went
    /// through TURN, for the log and the monthly TURN tally.
    private var lastTransportBytes: Double = 0
    private var sessionBytes: Double = 0
    private var sessionTurnBytes: Double = 0
    private var startedAt = Date()

    private let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

    init(signaling: SignalingChannel, device: DeviceInfo, queue: DispatchQueue) {
        self.signaling = signaling
        self.device = device
        self.queue = queue
        super.init()
    }

    // MARK: Lifecycle (call on `queue`)

    func start() {
        let quality = HostConfig.shared.quality
        let factory = Self.factory

        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.continualGatheringPolicy = .gatherContinually
        // Direct links (LAN, Tailscale) need none; relayed viewers get STUN and maybe TURN.
        config.iceServers = signaling.iceServers.compactMap(Self.iceServer)

        guard let peerConnection = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            end(reason: "WebRTC 연결을 만들 수 없습니다")
            return
        }
        self.peerConnection = peerConnection

        let source = factory.videoSource(forScreenCast: true)
        let track = factory.videoTrack(with: source, trackId: "screen")

        let encoding = RTCRtpEncodingParameters()
        encoding.isActive = true
        // JUMP_MAX_KBPS caps the bitrate like a slow connection would (for testing).
        let maxBitrate = ProcessInfo.processInfo.environment["JUMP_MAX_KBPS"].flatMap(Int.init).map { $0 * 1000 }
            ?? quality.maxBitrateBps
        encoding.maxBitrateBps = NSNumber(value: maxBitrate)
        encoding.maxFramerate = 60
        encoding.networkPriority = .high
        let transceiverInit = RTCRtpTransceiverInit()
        transceiverInit.direction = .sendOnly
        transceiverInit.streamIds = ["screen"]
        transceiverInit.sendEncodings = [encoding]
        if let transceiver = peerConnection.addTransceiver(with: track, init: transceiverInit) {
            preferCodecs(transceiver, hevc: HostConfig.shared.useHEVC && device.receivesHEVC)
            let parameters = transceiver.sender.parameters
            // Under congestion keep the frame rate and lower the resolution (smooth over sharp).
            parameters.degradationPreference = NSNumber(value: RTCDegradationPreference.maintainFramerate.rawValue)
            transceiver.sender.parameters = parameters
        }

        let channelConfig = RTCDataChannelConfiguration()
        channelConfig.isOrdered = true
        inputChannel = peerConnection.dataChannel(forLabel: "input", configuration: channelConfig)
        inputChannel?.delegate = self

        if HostConfig.shared.sendAudio {
            // Late audio is useless: no ordering, no retransmits.
            let audioConfig = RTCDataChannelConfiguration()
            audioConfig.isOrdered = false
            audioConfig.maxRetransmits = 0
            audioChannel = peerConnection.dataChannel(forLabel: "audio", configuration: audioConfig)
        }

        // Start near a usable bitrate instead of WebRTC's conservative default ramp, and keep a
        // 2 Mbps floor: one Wi-Fi latency spike otherwise drops the estimate to ~1 Mbps and it
        // takes ~15 s to climb back, which reads as a long run of smeared, stuttering frames.
        peerConnection.setBweMinBitrateBps(NSNumber(value: min(2_000_000, maxBitrate)),
                                           currentBitrateBps: NSNumber(value: min(8_000_000, maxBitrate)),
                                           maxBitrateBps: NSNumber(value: maxBitrate))

        videoSource = source
        // The monitor picked last time, if it is still attached.
        let preferred = HostConfig.shared.displayID.flatMap { Displays.isActive($0) ? $0 : nil } ?? CGMainDisplayID()
        // A virtual display the size of the viewer's screen when that is turned on; whatever goes
        // wrong with it, the session starts on the real screen instead.
        let device = self.device
        DispatchQueue.main.async { [weak self] in
            VirtualDisplayManager.shared.prepare(for: device) { virtual in
                self?.queue.async {
                    guard let self, !self.stopped else { return }
                    self.startCapture(displayID: virtual ?? preferred)
                }
            }
        }
    }

    /// (Re)starts screen capture on one display, feeding the same video track.
    private func startCapture(displayID: CGDirectDisplayID) {
        guard let source = videoSource else { return }
        let firstStart = capturer == nil && self.displayID == nil
        capturer?.onStop = nil
        capturer?.stop()

        let capturer = ScreenCapturer(source: source)
        capturer.onStop = { [weak self, weak capturer] error in
            self?.queue.async {
                guard let self, let capturer else { return }
                self.captureStopped(capturer, error: error)
            }
        }
        if let audioChannel {
            // Weak: once the session closes the channel is gone and packets are simply dropped.
            capturer.onAudio = { [weak audioChannel] pcm in
                guard let channel = audioChannel, channel.readyState == .open,
                      channel.bufferedAmount < 64 * 1024 // congested: drop instead of adding delay
                else { return }
                channel.sendData(RTCDataBuffer(data: pcm, isBinary: true))
            }
        }
        self.capturer = capturer

        let maxLongEdge = streamLongEdge(for: displayID)
        let showsCursor = !device.drawsCursor
        Task { [weak self] in
            do {
                let started = try await capturer.start(displayID: displayID, maxLongEdge: maxLongEdge, showsCursor: showsCursor)
                self?.queue.async {
                    guard let self, self.capturer === capturer else { return }
                    self.captureStarted(started, first: firstStart)
                }
            } catch {
                self?.queue.async {
                    guard let self, self.capturer === capturer else { return }
                    self.end(reason: "화면을 캡처할 수 없습니다. 화면 기록 권한을 확인하세요. (\(error.localizedDescription))")
                }
            }
        }
    }

    /// The captured display went away or changed under the stream (a monitor unplugged, the lid
    /// closed, the virtual display removed): carry on with the Mac's main display instead of
    /// ending the session, a few times at most.
    private func captureStopped(_ capturer: ScreenCapturer, error: Error?) {
        guard !stopped, !finishing, self.capturer === capturer else { return }
        let why = error?.localizedDescription ?? "알 수 없음"
        guard captureRestarts < 3 else {
            return end(reason: "화면 캡처가 멈췄습니다: \(why)")
        }
        captureRestarts += 1
        hostLog("[session] capture stopped (\(why)); restarting on the main display (\(captureRestarts)/3)")
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.stopped, !self.finishing, self.capturer === capturer else { return }
            self.startCapture(displayID: CGMainDisplayID())
        }
    }

    /// The quality's size cap, lowered to what the viewer's screen can show (with a quarter more for
    /// zooming in): pixels beyond that cost frames and bandwidth and the viewer scales them away.
    private func streamLongEdge(for displayID: CGDirectDisplayID) -> Int? {
        let cap = HostConfig.shared.quality.maxLongEdge
        let bounds = CGDisplayBounds(displayID)
        // A display this process hasn't heard about yet reports no size: don't size by it.
        guard device.width > 0, device.height > 0, bounds.width > 0, bounds.height > 0 else { return cap }
        let aspect = max(bounds.width, bounds.height) / max(min(bounds.width, bounds.height), 1)
        // The Mac fitted onto the viewer's screen in whichever orientation shows it bigger.
        let fitted = min(Double(max(device.width, device.height)), Double(min(device.width, device.height)) * aspect)
        let wanted = max(1280, Int(fitted * 1.25))
        let edge = cap.map { min($0, wanted) } ?? wanted
        hostLog("[session] viewer \(device.width)x\(device.height): streaming up to \(edge) px wide")
        return edge
    }

    /// Client picked another monitor.
    private func switchDisplay(to id: CGDirectDisplayID) {
        guard !stopped, id != displayID, Displays.isActive(id) else {
            sendDisplays() // refresh the client's list either way
            return
        }
        hostLog("[session] switching to display \(id)")
        HostConfig.shared.displayID = id
        startCapture(displayID: id)
    }

    /// `{"t":"displays","current":id,"list":[{id,name,w,h,main}]}` so the client can offer a switch.
    private func sendDisplays() {
        guard let channel = inputChannel, channel.readyState == .open else { return }
        let list = Displays.list().map { display -> [String: Any] in
            ["id": Int(display.id), "name": display.name, "w": Int(display.size.width), "h": Int(display.size.height),
             "main": display.isMain]
        }
        send(["t": "displays", "current": Int(displayID ?? 0), "list": list], on: channel)
    }

    /// Ends the session from the host's side: tells the viewer why on the data channel (it may
    /// have no signaling left), then tears down once that had a moment to go out.
    func finish(bye: [String: Any]?) {
        finishing = true
        if let bye { reply(bye) }
        queue.asyncAfter(deadline: .now() + 0.25) { self.stop() }
    }

    /// Tears everything down without notifying anyone. Idempotent.
    func stop() {
        guard !stopped else { return }
        stopped = true
        if statsTimer != nil {
            hostLog(String(format: "[session] summary: %.1f min, %.2f GB sent, %.2f GB of it through TURN",
                           Date().timeIntervalSince(startedAt) / 60, sessionBytes / 1e9, sessionTurnBytes / 1e9))
        }
        capturer?.stop()
        capturer = nil
        inputChannel?.delegate = nil
        inputChannel?.close()
        inputChannel = nil
        audioChannel?.close()
        audioChannel = nil
        // close() joins WebRTC's threads, so no input message can race releaseAll().
        peerConnection?.close()
        peerConnection = nil
        cursorTracker.stop()
        clipboard.stop()
        statsTimer?.cancel()
        statsTimer = nil
        injector.releaseAll()
    }

    func handleSignal(_ message: [String: Any]) {
        guard !stopped, let peerConnection else { return }
        switch message["type"] as? String {
        case "answer":
            guard let sdp = message["sdp"] as? String else { return }
            let answer = RTCSessionDescription(type: .answer, sdp: sdp)
            peerConnection.setRemoteDescription(answer) { [weak self] error in
                self?.queue.async {
                    guard let self else { return }
                    if let error {
                        self.end(reason: "answer 적용 실패: \(error.localizedDescription)")
                        return
                    }
                    self.remoteDescriptionSet = true
                    self.pendingCandidates.forEach(self.addCandidate)
                    self.pendingCandidates.removeAll()
                }
            }
        case "candidate":
            guard let candidateSdp = message["candidate"] as? String, !candidateSdp.isEmpty else { return }
            let candidate = RTCIceCandidate(sdp: candidateSdp,
                                            sdpMLineIndex: Int32((message["sdpMLineIndex"] as? NSNumber)?.intValue ?? 0),
                                            sdpMid: message["sdpMid"] as? String)
            if remoteDescriptionSet {
                addCandidate(candidate)
            } else {
                pendingCandidates.append(candidate)
            }
        default:
            break
        }
    }

    // MARK: Private (on `queue`)

    private func end(reason: String?) {
        guard !stopped else { return }
        stop()
        if let reason {
            hostLog("[session] ended: \(reason)")
            signaling.fail(reason)
        } else {
            signaling.close()
        }
        onEvent?(.ended(reason: reason))
    }

    private func captureStarted(_ started: ScreenCapturer.Started, first: Bool) {
        guard !stopped else { return }
        displayID = started.displayID
        injector.setDisplay(started.displayID)
        displayMessage = [
            "t": "display",
            "id": Int(started.displayID),
            "w": Int(started.pointSize.width),
            "h": Int(started.pointSize.height),
            "pw": Int(started.pixelSize.width),
            "ph": Int(started.pixelSize.height),
        ]
        guard first else {
            // Switched monitors: new size and position mapping for the client, cursor follows.
            if let channel = inputChannel, channel.readyState == .open, let displayMessage { send(displayMessage, on: channel) }
            sendDisplays()
            if device.drawsCursor { cursorTracker.setDisplay(started.displayID) }
            return
        }
        createOffer()
        startStatsLog()
        startClipboardSync()
        if device.drawsCursor { startCursorTracking(displayID: started.displayID) }
    }

    private func startClipboardSync() {
        weak var channel = inputChannel
        clipboard.onCopy = { text in
            guard HostConfig.shared.shareClipboard, let channel, channel.readyState == .open,
                  let data = try? JSONSerialization.data(withJSONObject: ["t": "clip", "text": text])
            else { return }
            channel.sendData(RTCDataBuffer(data: data, isBinary: false))
        }
        clipboard.start()
    }

    private func startCursorTracking(displayID: CGDirectDisplayID) {
        weak var channel = inputChannel
        cursorTracker.onPosition = { position in
            guard let channel, channel.readyState == .open,
                  let data = try? JSONSerialization.data(withJSONObject: ["t": "cursor", "x": position.x, "y": position.y])
            else { return }
            channel.sendData(RTCDataBuffer(data: data, isBinary: false))
        }
        cursorTracker.onImage = { [weak self] message in
            self?.queue.async {
                guard let self, !self.stopped else { return }
                self.cursorImageMessage = message
                if let channel = self.inputChannel, channel.readyState == .open { self.send(message, on: channel) }
            }
        }
        cursorTracker.start(displayID: displayID)
    }

    /// One line every 5 s: what the encoder is actually doing, and why it's held back.
    private func startStatsLog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            self?.peerConnection?.statistics { report in
                var parts: [String] = []
                var bytesSent: Double?
                var transportBytes: Double?
                var viaTurn = false
                func number(_ value: NSObject?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
                for stat in report.statistics.values {
                    let v = stat.values
                    switch stat.type {
                    case "outbound-rtp" where (v["kind"] as? String) == "video":
                        bytesSent = number(v["bytesSent"])
                        if let codecId = v["codecId"] as? String,
                           let mime = report.statistics[codecId]?.values["mimeType"] as? String {
                            parts.append(mime.replacingOccurrences(of: "video/", with: ""))
                        }
                        parts.append(String(format: "out %.0fx%.0f %.0ffps limit=%@ target=%.1fMbps",
                                            number(v["frameWidth"]), number(v["frameHeight"]), number(v["framesPerSecond"]),
                                            (v["qualityLimitationReason"] as? String) ?? "?", number(v["targetBitrate"]) / 1e6))
                    case "media-source" where (v["kind"] as? String) == "video":
                        parts.append(String(format: "capture %.0ffps", number(v["framesPerSecond"])))
                    case "transport":
                        // The pair actually carrying media, and whether it's direct or via TURN.
                        transportBytes = number(v["bytesSent"])
                        guard let pairId = v["selectedCandidatePairId"] as? String,
                              let pair = report.statistics[pairId]?.values else { break }
                        func kind(_ id: NSObject?) -> String {
                            guard let id = id as? String, let c = report.statistics[id]?.values else { return "?" }
                            return (c["candidateType"] as? String) ?? "?"
                        }
                        // A relay candidate on either end: everything goes through Cloudflare TURN.
                        viaTurn = kind(pair["localCandidateId"]) == "relay" || kind(pair["remoteCandidateId"]) == "relay"
                        parts.append(String(format: "path %@->%@ rtt %.0fms avail=%.1fMbps",
                                            kind(pair["localCandidateId"]), kind(pair["remoteCandidateId"]),
                                            number(pair["currentRoundTripTime"]) * 1000,
                                            number(pair["availableOutgoingBitrate"]) / 1e6))
                    default:
                        break
                    }
                }
                self?.queue.async {
                    guard let self else { return }
                    let now = CACurrentMediaTime()
                    if let bytesSent, self.lastStatsTime > 0 {
                        parts.append(String(format: "sent %.1fMbps", (bytesSent - self.lastBytesSent) * 8 / (now - self.lastStatsTime) / 1e6))
                    }
                    self.lastBytesSent = bytesSent ?? 0
                    self.lastStatsTime = now
                    if let transportBytes {
                        let delta = max(0, transportBytes - self.lastTransportBytes)
                        self.lastTransportBytes = transportBytes
                        self.sessionBytes += delta
                        if viaTurn {
                            self.sessionTurnBytes += delta
                            HostConfig.shared.addTurnBytes(delta)
                        }
                    }
                    hostLog("[stats] %@", parts.joined(separator: " | "))
                }
            }
        }
        timer.resume()
        statsTimer = timer
    }

    private func createOffer() {
        peerConnection?.offer(for: constraints) { [weak self] sdp, error in
            self?.queue.async {
                guard let self, !self.stopped else { return }
                guard let sdp, error == nil else {
                    self.end(reason: "offer 생성 실패: \(error?.localizedDescription ?? "")")
                    return
                }
                self.peerConnection?.setLocalDescription(sdp) { error in
                    self.queue.async {
                        if let error {
                            self.end(reason: "offer 적용 실패: \(error.localizedDescription)")
                            return
                        }
                        var offer: [String: Any] = ["type": "offer", "sdp": sdp.sdp]
                        // The viewer gathers with the same STUN/TURN servers (TURN only after auth).
                        if !self.signaling.iceServers.isEmpty { offer["iceServers"] = self.signaling.iceServers }
                        self.signaling.send(offer)
                    }
                }
            }
        }
    }

    /// `{"urls": String | [String], "username"?, "credential"?}` -> RTCIceServer.
    private static func iceServer(_ entry: [String: Any]) -> RTCIceServer? {
        let urls = (entry["urls"] as? [String]) ?? (entry["urls"] as? String).map { [$0] } ?? []
        guard !urls.isEmpty else { return nil }
        return RTCIceServer(urlStrings: urls, username: entry["username"] as? String,
                            credential: entry["credential"] as? String)
    }

    private func addCandidate(_ candidate: RTCIceCandidate) {
        peerConnection?.add(candidate) { error in
            if let error { hostLog("[session] addIceCandidate failed: \(error.localizedDescription)") }
        }
    }

    /// HEVC first when the client can take it (same quality for ~40% fewer bits), then H.264
    /// (hardware on both ends, High before Baseline); everything else stays as a fallback.
    private func preferCodecs(_ transceiver: RTCRtpTransceiver, hevc: Bool) {
        let all = Self.factory.rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindVideo).codecs
        let isHEVC = { (codec: RTCRtpCodecCapability) in codec.name.uppercased() == "H265" }
        let hevcCodecs = hevc ? all.filter(isHEVC) : []
        let codecs = all.filter { !isHEVC($0) }
        func isH264(_ codec: RTCRtpCodecCapability) -> Bool { codec.name.uppercased() == "H264" }
        func rank(_ codec: RTCRtpCodecCapability) -> Int {
            let profile = codec.parameters["profile-level-id"] ?? ""
            let packetization = codec.parameters["packetization-mode"] ?? "0"
            return (profile.hasPrefix("64") ? 0 : 2) + (packetization == "1" ? 0 : 1)
        }
        let h264 = codecs.filter(isH264).sorted { rank($0) < rank($1) }
        let others = codecs.filter { !isH264($0) }
        // Swift resolves this to the deprecated non-throwing overload; failure just keeps the default order.
        hostLog("[session] preferring \(hevcCodecs.isEmpty ? "H264" : "H265") for \(device.name)")
        transceiver.setCodecPreferences(hevcCodecs + h264 + others)
    }
}

// MARK: RTCPeerConnectionDelegate (WebRTC signaling thread)

extension StreamSession: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.signaling.send([
                "type": "candidate",
                "candidate": candidate.sdp,
                "sdpMid": candidate.sdpMid ?? "0",
                "sdpMLineIndex": candidate.sdpMLineIndex,
            ])
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            switch newState {
            case .connected:
                self.onEvent?(.connected)
            case .failed:
                self.end(reason: "연결이 끊어졌습니다")
            case .disconnected:
                hostLog("[session] WebRTC link interrupted (waiting for it to come back or fail)")
            default:
                break
            }
        }
    }
}

// MARK: RTCDataChannelDelegate (WebRTC network thread)

extension StreamSession: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.readyState == .closed {
            // The viewer closed its connection (✕, a closed page): nothing else will say so now
            // that signaling may be gone.
            queue.async { [weak self] in
                guard let self, !self.stopped, dataChannel === self.inputChannel else { return }
                self.end(reason: nil)
            }
            return
        }
        guard dataChannel.readyState == .open else { return }
        queue.async { [weak self] in
            guard let self, let message = self.displayMessage else { return }
            self.send(message, on: dataChannel)
            if let cursorImage = self.cursorImageMessage { self.send(cursorImage, on: dataChannel) }
            if dataChannel === self.inputChannel { self.sendDisplays() }
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let message = (try? JSONSerialization.jsonObject(with: buffer.data)) as? [String: Any] else { return }
        switch message["t"] as? String {
        case "ping":
            send(["t": "pong", "ts": message["ts"] ?? 0], on: dataChannel)
        case "audio":
            let on = message["on"] as? Bool ?? true
            queue.async { [weak self] in
                guard let self, !self.stopped else { return }
                self.onEvent?(.clientAudio(on: on))
            }
        case "clip":
            // In line with the input, so a ⌘V queued behind it already sees it.
            if HostConfig.shared.shareClipboard, let text = message["text"] as? String, !text.isEmpty {
                let clipboard = self.clipboard
                injector.enqueue { clipboard.apply(text) }
            }
        case "selectDisplay":
            guard let id = (message["id"] as? NSNumber)?.uint32Value else { return }
            queue.async { [weak self] in self?.switchDisplay(to: CGDirectDisplayID(id)) }
        case "password":
            let current = message["current"] as? String ?? ""
            let new = message["new"] as? String ?? ""
            queue.async { [weak self] in
                guard let self, !self.stopped else { return }
                self.onEvent?(.passwordChange(current: current, new: new))
            }
        default:
            injector.handle(message)
        }
    }

    /// Sends a control message to the client on the input channel (call on `queue`).
    func reply(_ message: [String: Any]) {
        guard let channel = inputChannel, channel.readyState == .open else { return }
        send(message, on: channel)
    }

    private func send(_ message: [String: Any], on channel: RTCDataChannel) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        channel.sendData(RTCDataBuffer(data: data, isBinary: false))
    }
}
