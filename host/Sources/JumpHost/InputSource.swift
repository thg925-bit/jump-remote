import Carbon
import Foundation

/// The 한/영 key of a PC (Korean) keyboard. macOS ignores that key, so the host switches the
/// Mac's input source itself: Korean <-> the Latin layout used last (ABC, U.S., …).
enum InputSource {
    private static var lastLatinID: String?
    private static var lastKoreanID: String?

    /// Safe from any thread (Text Input Sources wants the main thread).
    static func toggleKorean() {
        if Thread.isMainThread { toggle() } else { DispatchQueue.main.sync { toggle() } }
    }

    private static func toggle() {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return }
        let sources = selectable()
        let target: TISInputSource?
        if isKorean(current) {
            lastKoreanID = id(of: current)
            target = sources.first { !isKorean($0) && id(of: $0) == lastLatinID }
                ?? sources.first { !isKorean($0) && flag(kTISPropertyInputSourceIsASCIICapable, $0) }
        } else {
            lastLatinID = id(of: current)
            target = sources.first { isKorean($0) && id(of: $0) == lastKoreanID } ?? sources.first(where: isKorean)
        }
        guard let target else {
            hostLog("[input] 한/영: no \(isKorean(current) ? "Latin" : "Korean") input source is enabled on this Mac")
            return
        }
        let status = TISSelectInputSource(target)
        hostLog("[input] 한/영 -> \(id(of: target) ?? "?")\(status == noErr ? "" : " failed (\(status))")")
    }

    /// Enabled keyboard layouts and input modes the user can switch to.
    private static func selectable() -> [TISInputSource] {
        let filter: [String: Any] = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsSelectCapable as String: true,
            kTISPropertyInputSourceIsEnabled as String: true,
        ]
        return (TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource]) ?? []
    }

    private static func property(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
    }

    private static func id(of source: TISInputSource) -> String? {
        property(source, kTISPropertyInputSourceID) as? String
    }

    private static func isKorean(_ source: TISInputSource) -> Bool {
        (property(source, kTISPropertyInputSourceLanguages) as? [String])?.first == "ko"
    }

    private static func flag(_ key: CFString, _ source: TISInputSource) -> Bool {
        (property(source, key) as? Bool) ?? false
    }
}
