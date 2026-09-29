import Foundation
import os

/// The host's own log: ~/Library/Logs/JumpHost/host.log (the previous one kept as host.1.log once
/// it passes 5 MB), and the unified log with the text public. NSLog's text shows up there only as
/// "<private>", which left dropped sessions impossible to explain afterwards.
enum HostLog {
    private static let logger = Logger(subsystem: "com.jihun.jumphost", category: "host")
    private static let queue = DispatchQueue(label: "jump.log", qos: .utility)
    private static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/JumpHost", isDirectory: true)
    /// A test instance (JUMP_DEFAULTS_SUITE) keeps its own file.
    private static let file = directory.appendingPathComponent(
        ProcessInfo.processInfo.environment["JUMP_DEFAULTS_SUITE"].map { "host-\($0).log" } ?? "host.log")
    private static let maxBytes: UInt64 = 5 << 20
    private static var handle: FileHandle?
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func write(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        let now = Date()
        queue.async { append("\(stamp.string(from: now)) \(message)\n") }
    }

    /// Where the log is, for the menu.
    static var path: URL { file }

    private static func append(_ line: String) {
        if handle == nil {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: file)
            _ = try? handle?.seekToEnd()
        }
        guard let handle else { return }
        handle.write(Data(line.utf8))
        if let size = try? handle.offset(), size > maxBytes {
            try? handle.close()
            self.handle = nil
            let old = file.deletingPathExtension().appendingPathExtension("1.log")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: file, to: old)
        }
    }
}

/// Drop-in for NSLog: formats with String(format:) only when there are arguments, so text that
/// happens to contain "%" is written as is.
func hostLog(_ format: String, _ arguments: CVarArg...) {
    HostLog.write(arguments.isEmpty ? format : String(format: format, arguments: arguments))
}
