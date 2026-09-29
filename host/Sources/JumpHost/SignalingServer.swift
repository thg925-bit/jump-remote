import CryptoKit
import Foundation

/// A viewer's signaling link: a direct WebSocket (LAN / Tailscale) or a relayed one.
protocol SignalingChannel: AnyObject {
    var onMessage: (([String: Any]) -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
    var remoteDescription: String { get }
    /// STUN/TURN servers the session should use (empty when peers can reach each other).
    var iceServers: [[String: Any]] { get }
    func send(_ message: [String: Any])
    /// Sends an error to the viewer, then closes. `retry`: the viewer should reconnect by itself
    /// (e.g. a setting changed), rather than show the error and stop.
    func fail(_ message: String, retry: Bool)
    func close()
}

extension SignalingChannel {
    func fail(_ message: String) { fail(message, retry: false) }

    static func errorMessage(_ message: String, retry: Bool) -> [String: Any] {
        var error: [String: Any] = ["type": "error", "message": message]
        if retry { error["retry"] = true }
        return error
    }
}

/// WebSocket listener that hands each incoming connection to `onConnection`.
final class SignalingServer {
    var onConnection: ((SignalingConnection) -> Void)?

    private var server: TCPServer?

    func start(port: UInt16, queue: DispatchQueue) throws {
        let server = TCPServer(queue: queue)
        server.onAccept = { [weak self] tcp in
            hostLog("[signaling] connection from \(tcp.remote)")
            let connection = SignalingConnection(tcp: tcp)
            self?.onConnection?(connection)
            connection.start()
        }
        try server.start(port: port)
        self.server = server
        hostLog("[signaling] listening on \(port)")
    }

    func stop() {
        server?.stop()
        server = nil
    }
}

/// One client WebSocket (RFC 6455, server side) carrying JSON text messages.
/// Runs on the server queue; call its methods from that queue.
final class SignalingConnection: SignalingChannel {
    var onMessage: (([String: Any]) -> Void)?
    var onClose: (() -> Void)?

    let remoteDescription: String
    let iceServers: [[String: Any]] = [] // LAN and Tailscale addresses are host candidates

    private let tcp: TCPConnection
    private var buffer = Data()
    private var upgraded = false
    /// Messages sent before the HTTP upgrade finished.
    private var outbox: [Data] = []
    private var fragments = Data()
    private var fragmentOpcode: UInt8 = 0
    private var closed = false

    private static let maxMessageSize = 1 << 20
    private static let handshakeGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    init(tcp: TCPConnection) {
        self.tcp = tcp
        self.remoteDescription = tcp.remote
    }

    deinit {
        tcp.close()
    }

    func start() {
        tcp.onData = { [weak self] data in self?.received(data) }
        tcp.onClose = { [weak self] in self?.close() }
        // Drop clients that never finish the handshake.
        tcp.queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            if let self, !self.upgraded { self.close() }
        }
    }

    func send(_ message: [String: Any]) {
        guard !closed, let json = try? JSONSerialization.data(withJSONObject: message) else { return }
        let frame = Self.frame(opcode: 0x1, payload: json)
        if upgraded {
            tcp.send(frame)
        } else {
            outbox.append(frame)
        }
    }

    func fail(_ message: String, retry: Bool) {
        send(Self.errorMessage(message, retry: retry))
        shutdown(closeCode: 1008)
    }

    func close() {
        guard !closed else { return }
        closed = true
        tcp.close()
        finish()
    }

    // MARK: Private

    private func shutdown(closeCode: UInt16) {
        guard !closed else { return }
        closed = true
        if upgraded {
            tcp.send(Self.frame(opcode: 0x8, payload: Data([UInt8(closeCode >> 8), UInt8(closeCode & 0xFF)])))
        }
        tcp.closeAfterSending()
        finish()
    }

    private func finish() {
        let callback = onClose
        onClose = nil
        onMessage = nil
        callback?()
    }

    private func received(_ data: Data) {
        buffer.append(data)
        if !upgraded {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > 16 * 1024 { close() }
                return
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            buffer = Data(buffer[end.upperBound...])
            guard upgrade(head) else { return }
        }
        parseFrames()
    }

    private func upgrade(_ head: String) -> Bool {
        let lines = head.components(separatedBy: "\r\n")
        func header(_ name: String) -> String? {
            let prefix = name.lowercased() + ":"
            return lines.first { $0.lowercased().hasPrefix(prefix) }
                .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
        }
        guard header("Upgrade")?.lowercased() == "websocket", let key = header("Sec-WebSocket-Key") else {
            tcp.send(Data("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            closed = true
            tcp.closeAfterSending()
            finish()
            return false
        }
        let accept = Data(Insecure.SHA1.hash(data: Data((key + Self.handshakeGUID).utf8))).base64EncodedString()
        tcp.send(Data("""
        HTTP/1.1 101 Switching Protocols\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Accept: \(accept)\r
        \r

        """.utf8))
        upgraded = true
        outbox.forEach(tcp.send)
        outbox.removeAll()
        return true
    }

    private func parseFrames() {
        while !closed {
            let bytes = [UInt8](buffer.prefix(14))
            guard bytes.count >= 2 else { return }
            let fin = bytes[0] & 0x80 != 0
            let opcode = bytes[0] & 0x0F
            let masked = bytes[1] & 0x80 != 0
            var length = Int(bytes[1] & 0x7F)
            var offset = 2
            if length == 126 {
                guard bytes.count >= 4 else { return }
                length = Int(bytes[2]) << 8 | Int(bytes[3])
                offset = 4
            } else if length == 127 {
                guard bytes.count >= 10 else { return }
                guard bytes[2] == 0, bytes[3] == 0, bytes[4] == 0, bytes[5] == 0 else {
                    close()
                    return
                }
                length = bytes[6..<10].reduce(0) { $0 << 8 | Int($1) }
                offset = 10
            }
            // Clients must mask; cap sizes so a peer can't make us buffer without bound.
            guard masked, length <= Self.maxMessageSize else {
                close()
                return
            }
            guard buffer.count >= offset + 4 + length else { return }

            let mask = [UInt8](buffer[offset..<(offset + 4)])
            var payload = [UInt8](buffer[(offset + 4)..<(offset + 4 + length)])
            for index in payload.indices {
                payload[index] ^= mask[index & 3]
            }
            buffer = Data(buffer[(offset + 4 + length)...])
            handleFrame(opcode: opcode, fin: fin, payload: Data(payload))
        }
    }

    private func handleFrame(opcode: UInt8, fin: Bool, payload: Data) {
        switch opcode {
        case 0x0: // continuation
            fragments.append(payload)
            guard fragments.count <= Self.maxMessageSize else {
                close()
                return
            }
            if fin {
                deliver(opcode: fragmentOpcode, payload: fragments)
                fragments = Data()
            }
        case 0x1, 0x2:
            if fin {
                deliver(opcode: opcode, payload: payload)
            } else {
                fragmentOpcode = opcode
                fragments = payload
            }
        case 0x8:
            shutdown(closeCode: 1000)
        case 0x9:
            tcp.send(Self.frame(opcode: 0xA, payload: payload))
        case 0xA:
            break
        default:
            close()
        }
    }

    private func deliver(opcode: UInt8, payload: Data) {
        guard opcode == 0x1,
              let message = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        else { return }
        onMessage?(message)
    }

    /// Unmasked server frame.
    private static func frame(opcode: UInt8, payload: Data) -> Data {
        var frame = Data([0x80 | opcode])
        let count = payload.count
        if count < 126 {
            frame.append(UInt8(count))
        } else if count <= 0xFFFF {
            frame.append(contentsOf: [126, UInt8(count >> 8), UInt8(count & 0xFF)])
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((count >> shift) & 0xFF))
            }
        }
        frame.append(payload)
        return frame
    }
}
