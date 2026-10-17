import AppKit

/// Shares copied text between the Mac and the client while a session runs: text copied on the
/// Mac goes to the client, text the client sends lands on the Mac pasteboard.
final class ClipboardSync {
    /// Text copied on the Mac, at most `maxBytes` of UTF-8. Called on the main thread.
    var onCopy: ((String) -> Void)?

    /// Keeps each message well under what every browser's data channel accepts.
    static let maxBytes = 60_000

    private var timer: Timer?
    private var lastChangeCount = 0

    /// Pasteboard changes the host made itself (client text, typing through paste): not echoed back.
    private static let lock = NSLock()
    private static var ownChanges: [Int] = []

    static func noteOwnChange(_ changeCount: Int) {
        lock.lock()
        ownChanges.append(changeCount)
        if ownChanges.count > 16 { ownChanges.removeFirst(ownChanges.count - 16) }
        lock.unlock()
    }

    private static func isOwnChange(_ changeCount: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ownChanges.contains(changeCount)
    }

    func start() {
        DispatchQueue.main.async {
            guard self.timer == nil else { return }
            // Only what is copied from now on; whatever was on the pasteboard stays private.
            self.lastChangeCount = NSPasteboard.general.changeCount
            let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in self?.poll() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    func stop() {
        DispatchQueue.main.async {
            self.timer?.invalidate()
            self.timer = nil
        }
    }

    /// Puts the client's text on the Mac pasteboard. Synchronous: called on the input queue, so
    /// a paste keystroke queued behind it already sees it.
    func apply(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        Self.noteOwnChange(pasteboard.changeCount)
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        guard !Self.isOwnChange(changeCount),
              let text = pasteboard.string(forType: .string), !text.isEmpty
        else { return }
        guard text.utf8.count <= Self.maxBytes else {
            hostLog("[clipboard] copied text too large to share (\(text.utf8.count) bytes)")
            return
        }
        onCopy?(text)
    }
}
