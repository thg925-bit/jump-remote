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
        /// The relay turned this Mac away (why, for the menu); it keeps trying slowly, so a fix
        /// on the relay's side applies by itself.
        case rejected(String)
    }

    var onViewer: ((RelayChannel) -> Void)?
    /// Called on `queue`.
    var onStateChange: ((State) -> Void)?
    /// Called on `queue`: true when the relay serves an older (or newer) viewer page than this
    /// Mac's, i.e. the relay needs deploying again.
    var onViewerStale: ((Bool) -> Void)?

    private(set) var state: State = .offline {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    /// STUN always; TURN when the relay has credentials. Refreshed on every (re)connect.
    private(set) var iceServers: [[String: Any]] = [["urls": "stun:stun.cloudflare.com:3478"]]

    private let url: URL
    private let base: URL
    private let queue: DispatchQueue
    private var viewerCheckedAt: Date?
    private var viewerStale = false
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
        self.base = base
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
        if case .rejected = state {} else { state = .connecting }
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
                    let status = (task.response as? HTTPURLResponse)?.statusCode
                    let close = task.closeCode.rawValue
                    let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    hostLog("[relay] link lost: \(error.localizedDescription)"
                            + (status.map { $0 == 101 ? "" : " (HTTP \($0))" } ?? "")
                            + (close != 0 ? " (close \(close) \(reason))" : ""))
                    if let status, [400, 403, 409].contains(status) {
                        self.rejected(task, status: status)
                    } else {
                        self.lost(task)
                    }
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
            checkViewer()
        }

        switch message["relay"] as? String {
        case "open":
            guard let cid = message["cid"] as? String else { return }
            // Fresh TURN credentials per viewer (they expire after a day); the reply lands
            // well before the viewer finishes authenticating and the session starts.
            send(["relay": "turn"])
            let channel = RelayChannel(cid: cid, ip: message["ip"] as? String, client: self)
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

    /// Refused at the handshake: say why, and try again only now and then.
    private func rejected(_ task: URLSessionWebSocketTask, status: Int) {
        guard self.task === task else { return }
        disconnect()
        let why = switch status {
        case 409: "이 Mac의 등록 정보가 중개 서버와 다릅니다"
        case 403: "중개 서버가 이 Mac을 받지 않습니다"
        default: "중개 서버 주소나 Mac ID가 맞지 않습니다"
        }
        state = .rejected(why)
        guard !stopped else { return }
        queue.asyncAfter(deadline: .now() + 60) { [weak self] in self?.connect() }
    }

    /// Compares the relay's viewer page with this Mac's: every few hours, or on every reconnect
    /// while they differ (a redeploy restarts the relay, so the link comes back right after it).
    private func checkViewer() {
        if !viewerStale, let last = viewerCheckedAt, Date().timeIntervalSince(last) < 6 * 3600 { return }
        viewerCheckedAt = Date()
        guard let local = Bundle.main.resourceURL.flatMap({ try? Data(contentsOf: $0.appendingPathComponent("web/index.html")) })
        else { return }
        var request = URLRequest(url: base)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        urlSession.dataTask(with: request) { [weak self] data, response, _ in
            guard let self, let data, (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let stale = data != local
            self.queue.async {
                if stale && !self.viewerStale { hostLog("[relay] its viewer page differs from this Mac's: deploy the relay again") }
                if !stale && self.viewerStale { hostLog("[relay] its viewer page is up to date again") }
                self.viewerStale = stale
                self.onViewerStale?(stale)
            }
        }.resume()
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
    let source: String
    var iceServers: [[String: Any]] { client?.iceServers ?? [] }

    private let cid: String
    private weak var client: RelayClient?
    private var closed = false

    /// `ip`: the viewer's address as the relay saw it (older relays don't send it).
    init(cid: String, ip: String?, client: RelayClient) {
        self.cid = cid
        self.client = client
        self.remoteDescription = "relay:\(cid)" + (ip.map { " (\($0))" } ?? "")
        self.source = ip ?? "relay"
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
