import AppKit
import WebRTC

/// Files between the viewer and the Mac on the `file` data channel (PROTOCOL.md, Files). What
/// the viewer sends lands in ~/Downloads; files copied on the Mac (⌘C in the Finder) are offered
/// to the viewer, which asks for them. One file comes in and one goes out at a time. All calls
/// on the session queue.
final class FileTransfer {
    static let chunkSize = 16 * 1024
    /// Stop feeding the channel above this and go on once it drained to half.
    static let maxBuffered: UInt64 = 1 << 20
    static let maxFileBytes: Int64 = 4 << 30
    static let maxOffered = 10

    /// The `file` channel, once the session made it.
    weak var channel: RTCDataChannel?
    /// Control messages for the viewer (on the input channel): fileSaved, fileError, fileOffer.
    var reply: (([String: Any]) -> Void)?
    private let deviceName: String

    private struct Incoming {
        let id: Int
        let name: String
        let size: Int64
        let url: URL
        let handle: FileHandle
        var received: Int64 = 0
    }
    private var incoming: Incoming?

    private struct Outgoing {
        let id: Int
        var files: [URL]
        var index = 0
        var handle: FileHandle?
        var sent: Int64 = 0
        var size: Int64 = 0
    }
    private var offers: [Int: [URL]] = [:]
    private var nextOfferID = 1
    private var outgoing: Outgoing?

    init(deviceName: String) {
        self.deviceName = deviceName
    }

    // MARK: Viewer -> Mac

    /// A text message on the file channel.
    func handle(text message: [String: Any]) {
        switch message["t"] as? String {
        case "file":
            begin(message)
        case "end":
            finish()
        case "abort":
            if let incoming {
                hostLog("[file] \(deviceName) stopped sending \(incoming.name)")
                discard()
            }
        default:
            break
        }
    }

    /// A chunk of the file being received.
    func handle(binary data: Data) {
        guard var incoming else { return }
        guard incoming.received + Int64(data.count) <= incoming.size else {
            fail(id: incoming.id, "크기가 맞지 않습니다")
            return
        }
        do {
            try incoming.handle.write(contentsOf: data)
        } catch {
            fail(id: incoming.id, "저장하지 못했습니다: \(error.localizedDescription)")
            return
        }
        incoming.received += Int64(data.count)
        self.incoming = incoming
    }

    private func begin(_ message: [String: Any]) {
        if incoming != nil { discard() }
        let id = (message["id"] as? NSNumber)?.intValue ?? 0
        let size = (message["size"] as? NSNumber)?.int64Value ?? -1
        let name = Self.safeName(message["name"] as? String)
        guard size >= 0, size <= Self.maxFileBytes else {
            fail(id: id, "파일이 너무 큽니다")
            return
        }
        guard let folder = Self.downloads() else {
            fail(id: id, "다운로드 폴더를 열 수 없습니다")
            return
        }
        let url = Self.uniqueURL(in: folder, name: name)
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url)
        else {
            fail(id: id, "다운로드 폴더에 쓸 수 없습니다")
            return
        }
        incoming = Incoming(id: id, name: url.lastPathComponent, size: size, url: url, handle: handle)
        hostLog("[file] receiving \(url.lastPathComponent) (\(Self.describe(size))) from \(deviceName)")
    }

    private func finish() {
        guard let incoming else { return }
        self.incoming = nil
        try? incoming.handle.close()
        guard incoming.received == incoming.size else {
            try? FileManager.default.removeItem(at: incoming.url)
            hostLog("[file] \(incoming.name): got \(incoming.received) of \(incoming.size) bytes; dropped")
            reply?(["t": "fileError", "id": incoming.id, "message": "전송이 중간에 끊겼습니다"])
            return
        }
        hostLog("[file] saved \(incoming.name) (\(Self.describe(incoming.size))) to Downloads")
        reply?(["t": "fileSaved", "id": incoming.id, "name": incoming.name])
    }

    private func fail(id: Int, _ message: String) {
        hostLog("[file] from \(deviceName): \(message)")
        discard()
        reply?(["t": "fileError", "id": id, "message": message])
    }

    /// Drops the file being received, and what was written of it.
    private func discard() {
        guard let incoming else { return }
        self.incoming = nil
        try? incoming.handle.close()
        try? FileManager.default.removeItem(at: incoming.url)
    }

    // MARK: Mac -> viewer

    /// Files copied on the Mac: offered to the viewer (`fileOffer`). False when there is nothing
    /// sendable among them.
    @discardableResult
    func offer(_ urls: [URL]) -> Bool {
        var files: [URL] = []
        var listed: [[String: Any]] = []
        for url in urls.prefix(Self.maxOffered) {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, let size = values.fileSize, Int64(size) <= Self.maxFileBytes
            else { continue }
            files.append(url)
            listed.append(["name": url.lastPathComponent, "size": size])
        }
        guard !files.isEmpty else { return false }
        let id = nextOfferID
        nextOfferID += 1
        offers = [id: files] // the newest copy is the one on offer
        hostLog("[file] offering \(listed.map { "\($0["name"] ?? "") (\(Self.describe(Int64($0["size"] as? Int ?? 0))))" }.joined(separator: ", ")) to \(deviceName)")
        reply?(["t": "fileOffer", "id": id, "files": listed])
        return true
    }

    /// The viewer wants an offered set: stream the files one after another.
    func send(offerID id: Int) {
        guard let files = offers[id] else {
            reply?(["t": "fileError", "id": id, "message": "그 파일은 더 이상 보낼 수 없습니다"])
            return
        }
        if outgoing != nil { stopSending() }
        outgoing = Outgoing(id: id, files: files)
        startNextFile()
    }

    /// The viewer gave up on the files on their way.
    func cancel(offerID id: Int) {
        guard outgoing?.id == id else { return }
        stopSending()
    }

    /// The channel drained: go on sending.
    func bufferedAmountChanged(_ amount: UInt64) {
        guard outgoing != nil, amount <= Self.maxBuffered / 2 else { return }
        pump()
    }

    private func startNextFile() {
        guard var out = outgoing, let channel else { return }
        guard out.index < out.files.count else {
            outgoing = nil
            return
        }
        let url = out.files[out.index]
        guard let handle = try? FileHandle(forReadingFrom: url),
              let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        else {
            hostLog("[file] can't read \(url.lastPathComponent)")
            reply?(["t": "fileError", "id": out.id, "message": "\(url.lastPathComponent)을(를) 읽을 수 없습니다"])
            out.index += 1
            outgoing = out
            return startNextFile()
        }
        out.handle = handle
        out.sent = 0
        out.size = Int64(size)
        outgoing = out
        hostLog("[file] sending \(url.lastPathComponent) (\(Self.describe(Int64(size)))) to \(deviceName)")
        Self.send(["t": "file", "id": out.id, "name": url.lastPathComponent, "size": size,
                   "index": out.index, "count": out.files.count], on: channel)
        pump()
    }

    /// Feeds chunks until the channel's buffer is full; `bufferedAmountChanged` calls again.
    private func pump() {
        guard var out = outgoing, let handle = out.handle, let channel else { return }
        while channel.bufferedAmount < Self.maxBuffered {
            let data = (try? handle.read(upToCount: Self.chunkSize)) ?? Data()
            if data.isEmpty {
                try? handle.close()
                Self.send(["t": "end", "id": out.id, "name": out.files[out.index].lastPathComponent], on: channel)
                out.handle = nil
                out.index += 1
                outgoing = out
                return startNextFile()
            }
            channel.sendData(RTCDataBuffer(data: data, isBinary: true))
            out.sent += Int64(data.count)
        }
        outgoing = out
    }

    private func stopSending() {
        try? outgoing?.handle?.close()
        outgoing = nil
    }

    /// The session is over: nothing half done stays behind.
    func stop() {
        discard()
        stopSending()
        offers.removeAll()
    }

    // MARK: Helpers

    private static func send(_ message: [String: Any], on channel: RTCDataChannel) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        channel.sendData(RTCDataBuffer(data: data, isBinary: false))
    }

    static func downloads() -> URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    /// A file name without a path in it, never hidden, never empty.
    static func safeName(_ raw: String?) -> String {
        var name = (raw ?? "").components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        return name.isEmpty ? "file" : String(name.prefix(200))
    }

    /// "a.png", then "a (2).png", "a (3).png" when that exists.
    static func uniqueURL(in folder: URL, name: String) -> URL {
        var url = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }

    static func describe(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
