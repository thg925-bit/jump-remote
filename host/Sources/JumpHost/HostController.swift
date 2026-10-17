import CryptoKit
import Foundation
import Security

/// Accepts signaling connections, authenticates them, and owns the single active session.
final class HostController {
    enum State: Equatable {
        case idle
        case connecting(device: String)
        case connected(device: String)
    }

    /// Called on `queue` whenever `state` changes.
    var onStateChange: ((State) -> Void)?

    private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    private let queue = DispatchQueue(label: "jump.host")
    private let server = SignalingServer()
    private let webServer = WebServer()
    private var relay: RelayClient?
    /// Called on `queue` when the relay link changes.
    var onRelayStateChange: ((RelayClient.State) -> Void)?
    /// Called on `queue`: whether the relay's viewer page is older than this Mac's.
    var onRelayViewerStale: ((Bool) -> Void)?
    private var session: StreamSession?
    /// Connections still authenticating; the session retains its connection after that.
    private var pendingConnections: [ObjectIdentifier: SignalingChannel] = [:]
    /// Wrong passwords per source (IP address), so a stranger guessing locks out only
    /// themselves: 5 misses within a minute lock that source for a minute, doubling with every
    /// further lockout up to an hour. A correct login forgives.
    private struct Strikes {
        var misses: [Date] = []
        var lockedUntil: Date?
        var lockouts = 0
        var last = Date()
    }
    private var strikes: [String: Strikes] = [:]
    /// Whether the connected client is playing our audio (it tells us when that changes).
    private var clientAudioOn = true

    private static let maxFailures = 5
    private static let failureWindow: TimeInterval = 60
    private static let maxLockout: TimeInterval = 3600

    func start() throws {
        server.onConnection = { [weak self] connection in self?.accept(connection) }
        try server.start(port: HostConfig.shared.port, queue: queue)
        try webServer.start(port: HostConfig.shared.webPort, queue: queue)
        startRelay()
    }

    /// (Re)connects to the Cloudflare relay if one is configured.
    func startRelay() {
        queue.async { [weak self] in
            guard let self else { return }
            self.relay?.stop()
            self.relay = nil
            let config = HostConfig.shared
            guard let base = config.relayURL else {
                self.onRelayStateChange?(.offline)
                return
            }
            let relay = RelayClient(base: base, macID: config.macID, token: config.relayToken, queue: self.queue)
            relay.onViewer = { [weak self] channel in self?.accept(channel) }
            relay.onStateChange = { [weak self] state in self?.onRelayStateChange?(state) }
            relay.onViewerStale = { [weak self] stale in self?.onRelayViewerStale?(stale) }
            relay.start()
            self.relay = relay
        }
    }

    /// Re-evaluates speaker muting after a setting changes.
    func refreshSpeakerPolicy() {
        queue.async { [weak self] in self?.applySpeakerPolicy() }
    }

    /// Drops the current client. `retry`: it reconnects by itself (e.g. after the quality setting
    /// changes, which only applies to a new session).
    func disconnect(reason: String, retry: Bool = false) {
        queue.async { [weak self] in self?.endSession(reason: reason, retry: retry) }
    }

    // MARK: Private (on `queue`)

    private func accept(_ connection: SignalingChannel) {
        var nonce = Data(count: 32)
        let status = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else {
            connection.close()
            return
        }

        let id = ObjectIdentifier(connection)
        pendingConnections[id] = connection
        var authenticated = false
        connection.onMessage = { [weak self, weak connection] message in
            guard let self, let connection else { return }
            if authenticated {
                if self.session?.signaling === connection {
                    self.session?.handleSignal(message)
                }
                return
            }
            guard message["type"] as? String == "auth" else {
                connection.fail("인증이 필요합니다")
                return
            }
            let source = connection.source
            if let locked = self.lockoutMessage(source) {
                connection.fail(locked)
                return
            }
            guard self.verify(message, nonce: nonce) else {
                hostLog("[host] auth failed from \(connection.remoteDescription)")
                self.recordFailure(source)
                connection.fail(self.lockoutMessage(source) ?? "비밀번호가 틀렸습니다")
                return
            }
            self.strikes[source] = nil
            authenticated = true
            self.pendingConnections[id] = nil
            let device = DeviceInfo(message["device"])
            // The viewer of the running session, back on a new socket after its network changed:
            // the same session goes on with an ICE restart instead of starting over.
            if let token = message["resume"] as? String, let session = self.session, session.canResume(token) {
                session.resume(on: connection)
                return
            }
            self.startSession(on: connection, device: device)
        }
        connection.onClose = { [weak self, weak connection] in
            guard let self else { return }
            self.pendingConnections[id] = nil
            guard let connection, self.session?.signaling === connection else { return }
            // Signaling only sets the session up. Once the picture flows, a dropped signaling socket
            // (a phone backgrounding the page, a mobile network, the relay) must not end it: the
            // session ends when the viewer closes the data channel or WebRTC fails.
            if case .connected = self.state {
                hostLog("[host] signaling closed; the session stays up")
                return
            }
            hostLog("[host] signaling closed before the session connected")
            self.endSession(reason: nil)
        }

        connection.send([
            "type": "challenge",
            "nonce": nonce.base64EncodedString(),
            "host": Host.current().localizedName ?? "Mac",
            "version": 1,
        ])
    }

    private func verify(_ message: [String: Any], nonce: Data) -> Bool {
        guard let encoded = message["hmac"] as? String,
              let mac = Data(base64Encoded: encoded)
        else { return false }
        let key = SymmetricKey(data: Data(HostConfig.shared.password.utf8))
        return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: nonce, using: key)
    }

    /// A connected client may change the password, but must still know the current one; wrong
    /// guesses count toward the same lockout as failed logins.
    private func changePassword(current: String, new: String, source: String) -> [String: Any] {
        if let locked = lockoutMessage(source) { return ["ok": false, "error": locked] }
        guard Self.sameSecret(current, HostConfig.shared.password) else {
            hostLog("[host] password change rejected: wrong current password")
            recordFailure(source)
            return ["ok": false, "error": lockoutMessage(source) ?? "현재 비밀번호가 틀렸습니다"]
        }
        guard new.count >= 8, new.count <= 128 else { return ["ok": false, "error": "새 비밀번호는 8자 이상이어야 합니다"] }
        guard new == new.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return ["ok": false, "error": "비밀번호 앞뒤에 공백을 넣을 수 없습니다"]
        }
        HostConfig.shared.setPassword(new)
        return ["ok": true]
    }

    /// Compares digests so the time taken doesn't depend on where the strings differ.
    private static func sameSecret(_ a: String, _ b: String) -> Bool {
        let x = Array(SHA256.hash(data: Data(a.utf8))), y = Array(SHA256.hash(data: Data(b.utf8)))
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// The message for a locked-out source, nil when it may try.
    private func lockoutMessage(_ source: String) -> String? {
        guard let until = strikes[source]?.lockedUntil, until > Date() else { return nil }
        let minutes = max(1, Int((until.timeIntervalSinceNow / 60).rounded(.up)))
        return "시도 횟수 초과. \(minutes)분 뒤 다시 시도하세요"
    }

    private func recordFailure(_ source: String) {
        let now = Date()
        strikes = strikes.filter { now.timeIntervalSince($0.value.last) < 6 * 3600 } // forget old ones
        var entry = strikes[source] ?? Strikes()
        entry.last = now
        entry.misses = entry.misses.filter { now.timeIntervalSince($0) < Self.failureWindow } + [now]
        if entry.misses.count >= Self.maxFailures {
            let length = min(Self.failureWindow * pow(2, Double(entry.lockouts)), Self.maxLockout)
            entry.lockedUntil = now.addingTimeInterval(length)
            entry.lockouts += 1
            entry.misses = []
            hostLog("[host] \(source) locked out for \(Int(length)) s after \(Self.maxFailures) wrong passwords")
        }
        strikes[source] = entry
    }

    private func startSession(on connection: SignalingChannel, device: DeviceInfo) {
        // One viewer at a time: the newest wins.
        endSession(reason: "다른 기기가 연결되어 세션이 종료되었습니다")

        hostLog("[host] session start: \(device.name) \(device.width)x\(device.height) from \(connection.remoteDescription)"
                + (device.reconnect.map { " — reconnecting after: \($0)" } ?? ""))
        SystemAwake.wakeDisplay()
        let session = StreamSession(signaling: connection, device: device, queue: queue)
        session.onEvent = { [weak self, weak session] event in
            guard let self, let session, self.session === session else { return }
            switch event {
            case .connected:
                self.state = .connected(device: session.device.name)
                SystemAwake.hold()
                self.applySpeakerPolicy()
            case .clientAudio(let on):
                hostLog("[audio] client playback \(on ? "on" : "off")")
                self.clientAudioOn = on
                self.applySpeakerPolicy()
            case .passwordChange(let current, let new):
                var reply = self.changePassword(current: current, new: new, source: session.signaling.source)
                reply["t"] = "password"
                if reply["ok"] as? Bool == true { hostLog("[host] password changed from \(session.device.name)") }
                session.reply(reply)
            case .ended(let reason):
                hostLog("[host] session ended: \(reason ?? "the viewer closed it")")
                self.session = nil
                self.state = .idle
                SpeakerMute.restore()
                SystemAwake.release()
                DispatchQueue.main.async { VirtualDisplayManager.shared.sessionEnded() }
            }
        }
        self.session = session
        clientAudioOn = true
        state = .connecting(device: device.name)
        session.start()
    }

    /// Sound plays in exactly one place: on the client when it's listening, otherwise on the Mac.
    private func applySpeakerPolicy() {
        let config = HostConfig.shared
        if case .connected = state, config.sendAudio, config.muteMacWhileConnected, clientAudioOn {
            SpeakerMute.mute()
        } else {
            SpeakerMute.restore()
        }
    }

    /// `reason` is sent to the client before closing; nil when the client already left.
    private func endSession(reason: String?, retry: Bool = false) {
        guard let session else { return }
        self.session = nil
        hostLog("[host] session end: \(reason ?? "signaling closed")\(retry ? " (the viewer reconnects)" : "")")
        // Say why on both paths: signaling may already be gone, the data channel is end to end.
        if let reason { session.signaling.fail(reason, retry: retry) }
        session.finish(bye: reason.map { ["t": "bye", "message": $0, "retry": retry] })
        SpeakerMute.restore()
        SystemAwake.release()
        DispatchQueue.main.async { VirtualDisplayManager.shared.sessionEnded() }
        state = .idle
    }
}
