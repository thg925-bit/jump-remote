import CoreGraphics
import Foundation
import Security

/// Persistent host settings (UserDefaults).
final class HostConfig {
    static let shared = HostConfig()

    /// WebSocket signaling. `JUMP_SIGNAL_PORT` overrides it (e.g. a second instance for testing).
    let port: UInt16 = HostConfig.environmentPort("JUMP_SIGNAL_PORT") ?? 47865
    /// Plain HTTP for the browser viewer. `JUMP_WEB_PORT` overrides it.
    let webPort: UInt16 = HostConfig.environmentPort("JUMP_WEB_PORT") ?? 47866

    private static func environmentPort(_ name: String) -> UInt16? {
        ProcessInfo.processInfo.environment[name].flatMap(UInt16.init)
    }

    /// `JUMP_DEFAULTS_SUITE` gives a test instance its own settings (password, relay), so it
    /// never changes the real host's.
    private let defaults = ProcessInfo.processInfo.environment["JUMP_DEFAULTS_SUITE"]
        .flatMap(UserDefaults.init(suiteName:)) ?? .standard

    enum Quality: String, CaseIterable {
        case original, balanced, saver

        var title: String {
            switch self {
            case .original: return "최고 (원본 해상도)"
            case .balanced: return "균형 (최대 2560px)"
            case .saver: return "절약 (최대 1600px)"
            }
        }

        /// Cap on the longer edge of the streamed frame, in pixels. nil = native.
        var maxLongEdge: Int? {
            switch self {
            case .original: return nil
            case .balanced: return 2560
            case .saver: return 1600
            }
        }

        var maxBitrateBps: Int {
            switch self {
            // Ceilings, not targets: WebRTC's estimate decides below them. 25 Mbps was hit
            // constantly on good links, where a busy screen then lost frames to stay under it.
            case .original: return 80_000_000
            case .balanced: return 50_000_000
            case .saver: return 8_000_000
            }
        }
    }

    var quality: Quality {
        get { Quality(rawValue: defaults.string(forKey: "quality") ?? "") ?? .balanced }
        set { defaults.set(newValue.rawValue, forKey: "quality") }
    }

    /// Use HEVC for clients that can decode it (falls back to H.264 otherwise).
    var useHEVC: Bool {
        get { defaults.object(forKey: "useHEVC") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "useHEVC") }
    }

    /// Stream the Mac's system audio to the client.
    var sendAudio: Bool {
        get { defaults.object(forKey: "sendAudio") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "sendAudio") }
    }

    /// Silence the Mac's speakers while a client is connected (audio still streams).
    var muteMacWhileConnected: Bool {
        get { defaults.object(forKey: "muteMacWhileConnected") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "muteMacWhileConnected") }
    }

    /// Bytes this Mac sent through Cloudflare TURN this calendar month (UTC), as Cloudflare
    /// counts the free 1,000 GB. Approximate: measured from this side of the connection.
    var turnBytesThisMonth: Double { defaults.double(forKey: Self.turnKey()) }

    func addTurnBytes(_ bytes: Double) {
        let key = Self.turnKey()
        defaults.set(defaults.double(forKey: key) + bytes, forKey: key)
    }

    private static func turnKey(_ date: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "turnBytes.%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    /// Share copied text between the Mac and the client.
    var shareClipboard: Bool {
        get { defaults.object(forKey: "shareClipboard") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "shareClipboard") }
    }

    /// The display the last session switched to; used first when it is still attached.
    var displayID: CGDirectDisplayID? {
        get { (defaults.object(forKey: "displayID") as? NSNumber).map { CGDirectDisplayID($0.uint32Value) } }
        set { defaults.set(newValue.map { NSNumber(value: $0) }, forKey: "displayID") }
    }

    /// Cloudflare relay origin (relay/), e.g. https://jump-relay.example.workers.dev. nil = off.
    /// `JUMP_RELAY_URL` overrides it; a build made for sharing carries a default in Info.plist.
    var relayURL: URL? {
        get {
            let raw = ProcessInfo.processInfo.environment["JUMP_RELAY_URL"]
                ?? defaults.string(forKey: "relayURL")
                ?? Bundle.main.object(forInfoDictionaryKey: "JumpRelayURL") as? String
            return raw.flatMap { $0.isEmpty ? nil : URL(string: $0) }
        }
        set { defaults.set(newValue?.absoluteString ?? "", forKey: "relayURL") } // "" = off, even over a baked-in default
    }

    /// This Mac's public name on the relay; viewers need it plus the password.
    var macID: String {
        if let existing = defaults.string(forKey: "macID"), !existing.isEmpty { return existing }
        let fresh = Self.randomString(length: 12)
        defaults.set(fresh, forKey: "macID")
        return fresh
    }

    /// Proves to the relay that this Mac owns `macID` (the first token used claims it).
    var relayToken: String {
        if let existing = defaults.string(forKey: "relayToken"), existing.count >= 32 { return existing }
        let fresh = Self.randomString(length: 48)
        defaults.set(fresh, forKey: "relayToken")
        return fresh
    }

    /// Link to open on the iPad / phone.
    var relayViewerLink: String? {
        guard let relayURL else { return nil }
        return "\(relayURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/#id=\(macID)"
    }

    var password: String {
        if let existing = defaults.string(forKey: "password"), !existing.isEmpty {
            return existing
        }
        return regeneratePassword()
    }

    func setPassword(_ password: String) {
        defaults.set(password, forKey: "password")
    }

    @discardableResult
    func regeneratePassword() -> String {
        let fresh = Self.randomString(length: 8)
        defaults.set(fresh, forKey: "password")
        return fresh
    }

    /// Lowercase letters and digits without look-alikes (0/o, 1/l/i).
    private static func randomString(length: Int) -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }
}
