import Foundation

/// Serves the bundled browser viewer (Resources/web) over plain HTTP.
final class WebServer {
    private var server: TCPServer?
    /// Connections stay alive here until they close.
    private var active: [ObjectIdentifier: TCPConnection] = [:]

    func start(port: UInt16, queue: DispatchQueue) throws {
        let server = TCPServer(queue: queue)
        server.onAccept = { [weak self] connection in self?.serve(connection) }
        try server.start(port: port)
        self.server = server
    }

    private func serve(_ connection: TCPConnection) {
        let id = ObjectIdentifier(connection)
        active[id] = connection
        connection.onClose = { [weak self] in self?.active[id] = nil }
        connection.queue.asyncAfter(deadline: .now() + 10) { [weak connection] in connection?.close() }

        var request = Data()
        connection.onData = { [weak connection] chunk in
            guard let connection else { return }
            request.append(chunk)
            guard let end = request.range(of: Data("\r\n\r\n".utf8)) else {
                if request.count > 16 * 1024 { connection.close() }
                return
            }
            connection.onData = nil
            let head = String(decoding: request[..<end.lowerBound], as: UTF8.self)
            let requestLine = head.components(separatedBy: "\r\n").first ?? ""
            let parts = requestLine.split(separator: " ")
            let path = parts.count > 1 ? String(parts[1]) : "/"
            let route = path.split(separator: "?").first.map(String.init) ?? "/"
            hostLog("[web] \(requestLine) from \(connection.remote)")

            if let (body, type) = Self.file(for: route) {
                connection.send(Self.head(status: "200 OK", type: type, length: body.count) + body)
            } else {
                let body = Data("Not found".utf8)
                connection.send(Self.head(status: "404 Not Found", type: "text/plain", length: body.count) + body)
            }
            connection.closeAfterSending()
        }
    }

    private static let contentTypes = [
        "html": "text/html; charset=utf-8",
        "webmanifest": "application/manifest+json",
        "png": "image/png",
    ]

    /// Flat files from the bundled web folder only: no subpaths, known extensions only.
    private static func file(for route: String) -> (Data, String)? {
        let name = route == "/" ? "index.html" : String(route.dropFirst())
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }),
              !name.hasPrefix("."),
              let type = contentTypes[(name as NSString).pathExtension.lowercased()],
              let directory = Bundle.main.resourceURL?.appendingPathComponent("web"),
              let data = try? Data(contentsOf: directory.appendingPathComponent(name))
        else { return nil }
        return (data, type)
    }

    private static func head(status: String, type: String, length: Int) -> Data {
        Data("""
        HTTP/1.1 \(status)\r
        Content-Type: \(type)\r
        Content-Length: \(length)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """.utf8)
    }
}
