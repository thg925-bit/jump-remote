import AppKit
import CoreGraphics

/// The Mac's attached displays, for the client's monitor switcher.
enum Displays {
    struct Info {
        let id: CGDirectDisplayID
        let name: String
        /// Size in points.
        let size: CGSize
        let isMain: Bool
    }

    /// Active displays, leaving out mirrors of another display.
    static func list() -> [Info] {
        let names = onMain(screenNames)
        return activeIDs().enumerated().map { index, id in
            Info(id: id, name: names[id] ?? "모니터 \(index + 1)", size: CGDisplayBounds(id).size,
                 isMain: CGDisplayIsMain(id) != 0)
        }
    }

    static func isActive(_ id: CGDirectDisplayID) -> Bool {
        activeIDs().contains(id)
    }

    private static func activeIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
    }

    /// "LG HDR 4K", "내장 Retina 디스플레이", … (AppKit, so main thread only).
    private static func screenNames() -> [CGDirectDisplayID: String] {
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                names[CGDirectDisplayID(number.uint32Value)] = screen.localizedName
            }
        }
        return names
    }

    private static func onMain<T>(_ work: () -> T) -> T {
        Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }
}
