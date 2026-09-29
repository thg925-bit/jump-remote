import Darwin
import Foundation

/// Minimal BSD-socket TCP server.
///
/// Network.framework's NWListener accepts connections arriving over Tailscale's utun
/// interface but never receives their data (reads time out); plain sockets work.
final class TCPServer {
    var onAccept: ((TCPConnection) -> Void)?

    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private var fd: Int32 = -1

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Listens on all interfaces, IPv4 and IPv6.
    func start(port: UInt16) throws {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.posixError("socket") }
        var yes: Int32 = 1
        var no: Int32 = 0
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &no, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        address.sin6_addr = in6addr_any
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bound == 0, listen(fd, 32) == 0 else {
            let error = errno == EADDRINUSE
                ? NSError(domain: "JumpHost", code: Int(EADDRINUSE),
                          userInfo: [NSLocalizedDescriptionKey: "포트 \(port)을(를) 다른 프로그램이 쓰고 있습니다"])
                : Self.posixError("bind \(port)")
            Darwin.close(fd)
            throw error
        }
        Self.setNonBlocking(fd)
        self.fd = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func acceptPending() {
        while true {
            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &length) }
            }
            guard client >= 0 else { return } // EAGAIN: drained
            var yes: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
            Self.setNonBlocking(client)
            let connection = TCPConnection(fd: client, remote: Self.describe(&storage, length), queue: queue)
            onAccept?(connection)
            connection.start()
        }
    }

    private static func describe(_ storage: inout sockaddr_storage, _ length: socklen_t) -> String {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var service = [CChar](repeating: 0, count: Int(NI_MAXSERV))
        let result = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, length, &host, socklen_t(host.count), &service, socklen_t(service.count),
                            NI_NUMERICHOST | NI_NUMERICSERV)
            }
        }
        guard result == 0 else { return "?" }
        var ip = String(cString: host)
        if ip.hasPrefix("::ffff:") { ip.removeFirst(7) }
        return "\(ip):\(String(cString: service))"
    }

    static func setNonBlocking(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    static func posixError(_ what: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "\(what): \(String(cString: strerror(errno)))"])
    }
}

/// One accepted socket. All callbacks run on the server's queue; call methods from it too.
final class TCPConnection {
    var onData: ((Data) -> Void)?
    var onClose: (() -> Void)?

    /// "ip:port" of the peer.
    let remote: String
    let queue: DispatchQueue

    private let fd: Int32
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var openSources = 0
    private var fdClosed = false
    private var pending = Data()
    private var closeWhenFlushed = false
    private var closed = false

    init(fd: Int32, remote: String, queue: DispatchQueue) {
        self.fd = fd
        self.remote = remote
        self.queue = queue
    }

    deinit {
        // Only reached with no live sources (their cancel handlers retain us).
        closeDescriptor()
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        adopt(source)
        source.resume()
        readSource = source
    }

    func send(_ data: Data) {
        guard !closed, !data.isEmpty else { return }
        pending.append(data)
        flush()
    }

    /// Closes once everything queued has been written.
    func closeAfterSending() {
        closeWhenFlushed = true
        if pending.isEmpty { close() }
    }

    func close() {
        guard !closed else { return }
        closed = true
        pending.removeAll()
        writeSource?.cancel()
        writeSource = nil
        readSource?.cancel()
        readSource = nil
        let callback = onClose
        onClose = nil
        onData = nil
        callback?()
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while !closed {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                onData?(Data(buffer[0..<count]))
            } else if count == 0 {
                close()
            } else if errno == EINTR {
                continue
            } else {
                if errno != EAGAIN && errno != EWOULDBLOCK { close() }
                return
            }
        }
    }

    private func flush() {
        while !pending.isEmpty && !closed {
            let written = pending.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                pending = pending.count == written ? Data() : Data(pending.dropFirst(written))
            } else if written < 0 && errno == EINTR {
                continue
            } else if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                armWriteSource()
                return
            } else {
                close()
                return
            }
        }
        writeSource?.cancel()
        writeSource = nil
        if closeWhenFlushed { close() }
    }

    private func armWriteSource() {
        guard writeSource == nil, !closed else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.flush() }
        adopt(source)
        source.resume()
        writeSource = source
    }

    /// The fd may only be closed after every dispatch source on it has been cancelled.
    /// The cancel handler holds `self` strongly until then, so owners must call close().
    private func adopt(_ source: DispatchSourceProtocol) {
        openSources += 1
        source.setCancelHandler {
            self.openSources -= 1
            if self.openSources == 0 && self.closed { self.closeDescriptor() }
        }
    }

    private func closeDescriptor() {
        guard !fdClosed else { return }
        fdClosed = true
        Darwin.close(fd)
    }
}
