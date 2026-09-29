import Foundation

/// Keeps this Mac registered with the Cloudflare relay (relay/) so viewers can reach it from
/// anywhere without Tailscale or port forwarding. Connects out, stays connected, reconnects
/// with backoff. Each relayed viewer becomes a `RelayChannel`; the rest of the host treats it
/// like a direct WebSocket. Media still flows peer to peer; only signaling passes through.
final class RelayClient: NSObject {
    enum State: Equatable {
        case offline
        case connecting
        case online
    }

    var onViewer: ((RelayChannel) -> Void)?
    /// Called on `queue`.
    var onStateChange: ((State) -> Void)?

    private(set) var state: State = .offline {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    /// STUN always; TURN when the relay has credentials. Refreshed on every (re)connect.
    private(set) var iceServers: [[String: Any]] = [["urls": "stun:stun.cloudflare.com:3478"]]

    private let url: URL
    private let queue: DispatchQueue
    private lazy var urlSession = URLSession(configuration: .default, delegate: nil, delegateQueue: nil)
    private var task: URLSessionWebSocketTask?
    private var channels: [String: RelayChannel] = [:]
    private var keepalive: DispatchSourceTimer?
    private var retryDelay: TimeInterval = 1
    private var stopped = false

    /// `base` is the relay origin, e.g. https://jump-relay.example.workers.dev
    init(base: URL, macID: String, token: String, queue: DispatchQueue) {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.scheme = base.scheme == "http" ? "ws" : "wss"
        components.path = "/host"
        components.queryItems = [URLQueryItem(name: "id", value: macID), URLQueryItem(name: "token", value: token)]
        self.url = components.url!
        self.queue = queue
        super.init()
    }

    func start() {
        queue.async { self.connect() }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.disconnect()
        }
    }

    // MARK: Used by RelayChannel (on `queue`)

    func send(_ message: [String: Any]) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8)
        else { return }
        task.send(.string(text)) { _ in }
    }

    func remove(_ cid: String) {
        channels[cid] = nil
    }

    // MARK: Private (on `queue`)

    private func connect() {
        guard !stopped, task == nil else { return }
        state = .connecting
        let task = urlSession.webSocketTask(with: url)
        task.maximumMessageSize = 1 << 20
        self.task = task
        task.resume()
        receive(on: task)
        send(["relay": "turn"])

        let keepalive = DispatchSource.makeTimerSource(queue: queue)
        keepalive.schedule(deadline: .now() + 25, repeating: 25)
        keepalive.setEventHandler { [weak self] in
            // The relay answers "ping" without waking; a failed send means the link is gone.
            self?.task?.send(.string("ping")) { error in
                if error != nil { self?.queue.async { self?.lost(task) } }
            }
        }
        keepalive.resume()
        self.keepalive = keepalive
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.task === task else { return }
                switch result {
                case .success(.string(let text)):
                    self.handle(text)
                    self.receive(on: task)
                case .success:
                    self.receive(on: task)
                case .failure(let error):
                    hostLog("[relay] link lost: \(error.localizedDescription)")
                    self.lost(task)
                }
            }
        }
    }

    private func handle(_ text: String) {
        if text == "pong" { return }
        guard let data = text.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        if state != .online {
            state = .online
            retryDelay = 1
            hostLog("[relay] online")
        }

        switch message["relay"] as? String {
        case "open":
            guard let cid = message["cid"] as? String else { return }
            // Fresh TURN credentials per viewer (they expire after a day); the reply lands
            // well before the viewer finishes authenticating and the session starts.
            send(["relay": "turn"])
            let channel = RelayChannel(cid: cid, client: self)
            channels[cid] = channel
            onViewer?(channel)
        case "close":
            guard let cid = message["cid"] as? String else { return }
            channels.removeValue(forKey: cid)?.remoteClosed()
        case "turn":
            if let servers = message["iceServers"] as? [[String: Any]], !servers.isEmpty { iceServers = servers }
        default:
            if let cid = message["cid"] as? String, let payload = message["msg"] as? String {
                channels[cid]?.deliver(payload)
            }
        }
    }

    private func lost(_ task: URLSessionWebSocketTask) {
        guard self.task === task else { return }
        disconnect()
        guard !stopped else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.connect() }
    }

    private func disconnect() {
        keepalive?.cancel()
        keepalive = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        let open = channels.values
        channels.removeAll()
        open.forEach { $0.remoteClosed() }
        state = .offline
    }
}

/// One viewer reached through the relay. Signaling messages travel as `{"cid","msg"}` envelopes.
final class RelayChannel: SignalingChannel {
    var onMessage: (([String: Any]) -> Void)?
    var onClose: (() -> Void)?

    let remoteDescription: String
    var iceServers: [[String: Any]] { client?.iceServers ?? [] }

    private let cid: String
    private weak var client: RelayClient?
    private var closed = false

    init(cid: String, client: RelayClient) {
        self.cid = cid
        self.client = client
        self.remoteDescription = "relay:\(cid)"
    }

    func send(_ message: [String: Any]) {
        guard !closed, let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8)
        else { return }
        client?.send(["cid": cid, "msg": text])
    }

    func fail(_ message: String, retry: Bool) {
        send(Self.errorMessage(message, retry: retry))
        close()
    }

    func close() {
        guard !closed else { return }
        closed = true
        client?.send(["relay": "close", "cid": cid])
        client?.remove(cid)
        finish()
    }

    func deliver(_ text: String) {
        guard !closed, let data = text.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        onMessage?(message)
    }

    /// The viewer or the relay link went away.
    func remoteClosed() {
        guard !closed else { return }
        closed = true
        finish()
    }

    private func finish() {
        let callback = onClose
        onClose = nil
        onMessage = nil
        callback?()
    }
}
