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
    private var session: StreamSession?
    /// Connections still authenticating; the session retains its connection after that.
    private var pendingConnections: [ObjectIdentifier: SignalingChannel] = [:]
    private var failedAttempts: [Date] = []
    /// Whether the connected client is playing our audio (it tells us when that changes).
    private var clientAudioOn = true

    private static let maxFailures = 5
    private static let lockoutWindow: TimeInterval = 60

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
            guard self.verify(message, nonce: nonce) else {
                self.failedAttempts.append(Date())
                hostLog("[host] auth failed from \(connection.remoteDescription)")
                connection.fail(self.isLockedOut() ? "시도 횟수 초과. 1분 뒤 다시 시도하세요" : "비밀번호가 틀렸습니다")
                return
            }
            authenticated = true
            self.startSession(on: connection, device: DeviceInfo(message["device"]))
            self.pendingConnections[id] = nil
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
        guard !isLockedOut(),
              let encoded = message["hmac"] as? String,
              let mac = Data(base64Encoded: encoded)
        else { return false }
        let key = SymmetricKey(data: Data(HostConfig.shared.password.utf8))
        return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: nonce, using: key)
    }

    /// A connected client may change the password, but must still know the current one; wrong
    /// guesses count toward the same lockout as failed logins.
    private func changePassword(current: String, new: String) -> [String: Any] {
        guard !isLockedOut() else { return ["ok": false, "error": "시도 횟수 초과. 1분 뒤 다시 시도하세요"] }
        guard Self.sameSecret(current, HostConfig.shared.password) else {
            failedAttempts.append(Date())
            hostLog("[host] password change rejected: wrong current password")
            return ["ok": false, "error": "현재 비밀번호가 틀렸습니다"]
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

    private func isLockedOut() -> Bool {
        let cutoff = Date().addingTimeInterval(-Self.lockoutWindow)
        failedAttempts.removeAll { $0 < cutoff }
        return failedAttempts.count >= Self.maxFailures
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
                var reply = self.changePassword(current: current, new: new)
                reply["t"] = "password"
                if reply["ok"] as? Bool == true { hostLog("[host] password changed from \(session.device.name)") }
                session.reply(reply)
            case .ended(let reason):
                hostLog("[host] session ended: \(reason ?? "the viewer closed it")")
                self.session = nil
                self.state = .idle
                SpeakerMute.restore()
                SystemAwake.release()
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
        state = .idle
    }
}
