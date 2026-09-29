import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

enum Permissions {
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }
    static var accessibility: Bool { AXIsProcessTrusted() }

    static func requestMissing() {
        if !screenRecording { CGRequestScreenCaptureAccess() }
        if !accessibility {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private static func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}

enum NetworkInfo {
    struct Address {
        let interface: String
        let ip: String
        var isTailscale: Bool { ip.hasPrefix("100.") && (64...127).contains(Int(ip.split(separator: ".")[1]) ?? 0) }
    }

    /// Non-loopback IPv4 addresses the client can reach this Mac on.
    static func addresses() -> [Address] {
        var result: [Address] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return result }
        defer { freeifaddrs(head) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  (Int32(entry.ifa_flags) & IFF_UP) != 0, (Int32(entry.ifa_flags) & IFF_LOOPBACK) == 0
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if ip.hasPrefix("169.254.") { continue }
            result.append(Address(interface: String(cString: entry.ifa_name), ip: ip))
        }
        return result
    }
}
