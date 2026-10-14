import CoreGraphics
import Foundation
import QuartzCore
import VirtualDisplayBridge

/// "접속 기기에 맞춘 가상 화면": while a viewer is connected, the Mac's desktop lives on a software
/// display made exactly as big as the viewer's screen, and the physical screens mirror it. No
/// black bars, and the picture is sent point for point instead of being scaled.
///
/// It must never cost a connection: whatever goes wrong here ends in `nil` ("use a real screen"),
/// and a display that is up stays up between sessions for a while, so a reconnect gets it at once.
/// Main thread only.
final class VirtualDisplayManager {
    static let shared = VirtualDisplayManager()

    struct Size: Equatable {
        let pixelsWide: Int
        let pixelsHigh: Int
        /// A Retina display: half that many points.
        let retina: Bool

        var scale: Int { retina ? 2 : 1 }
        var pointsWide: Int { pixelsWide / scale }
        var pointsHigh: Int { pixelsHigh / scale }
        var description: String { "\(pixelsWide)x\(pixelsHigh) px (\(pointsWide)x\(pointsHigh) pt @\(scale)x)" }
    }

    /// How long the display outlives a session: reconnects (a network blip, another device taking
    /// over, a setting changed) reuse it instead of reshuffling the Mac's screens again.
    private static let keepAfterSession: TimeInterval = 90
    /// Longest wait for macOS to bring the display up before giving up on it.
    private static let timeout: TimeInterval = 2.5

    private var display: JumpVirtualDisplay?
    private var size: Size?
    /// Physical displays made mirrors of ours.
    private var mirrored: [CGDirectDisplayID] = []
    private var removal: DispatchWorkItem?
    private var generation = 0

    /// The display to make for a viewer whose screen is `width` x `height` pixels: its screen in
    /// landscape, Retina when that still leaves a workable desktop (700 points high), else 1x.
    /// nil for sizes no desktop fits on.
    static func size(forViewerWidth width: Int, height: Int) -> Size? {
        var long = max(width, height), short = min(width, height)
        guard long >= 1024, short >= 600 else { return nil }
        let fit = min(1, Double(JumpVirtualDisplay.maxPixelsWide) / Double(long), Double(JumpVirtualDisplay.maxPixelsHigh) / Double(short))
        long = Int(Double(long) * fit)
        short = Int(Double(short) * fit)
        let retina = short / 2 >= 700
        let step = retina ? 4 : 2 // whole, even points
        return Size(pixelsWide: long / step * step, pixelsHigh: short / step * step, retina: retina)
    }

    /// Gets the display ready for `device` and calls back (on the main thread, exactly once) with
    /// its ID, or nil when the session should capture a physical screen as before.
    func prepare(for device: DeviceInfo, completion: @escaping (CGDirectDisplayID?) -> Void) {
        removal?.cancel()
        removal = nil
        guard HostConfig.shared.virtualDisplay else {
            remove()
            return completion(nil)
        }
        guard JumpVirtualDisplay.isSupported, let want = Self.size(forViewerWidth: device.width, height: device.height) else {
            hostLog("[display] no virtual display for \(device.name) \(device.width)x\(device.height)"
                    + (JumpVirtualDisplay.isSupported ? "" : " (this macOS no longer offers it)"))
            remove()
            return completion(nil)
        }

        // A viewer too small for Retina would get a plain 1x display, which is no sharper than
        // the Mac's own Retina screen scaled down for it (and reshuffles the desktop for nothing).
        // Only worth it when the Mac has no screen of its own: no monitor, or the lid closed.
        if !want.retina, !Self.physicalDisplays().isEmpty {
            hostLog("[display] \(device.name) \(device.width)x\(device.height) is not a Retina-size screen: using the Mac's own display")
            remove()
            return completion(nil)
        }

        if let display, size == want {
            hostLog("[display] reusing the virtual display \(want.description)")
            return completion(display.displayID)
        }

        generation += 1
        let attempt = generation
        let started = CACurrentMediaTime()
        if let display {
            // Another viewer size: resize in place rather than add and remove a monitor.
            if !display.setPixelsWide(UInt(want.pixelsWide), pixelsHigh: UInt(want.pixelsHigh), hiDPI: want.retina) { remove() }
        }
        if display == nil {
            display = JumpVirtualDisplay(named: "Jump", pixelsWide: UInt(want.pixelsWide), pixelsHigh: UInt(want.pixelsHigh),
                                         hiDPI: want.retina) { [weak self] in self?.terminated() }
        }
        guard let display else {
            hostLog("[display] macOS refused a virtual display \(want.description)")
            return completion(nil)
        }
        size = want

        // The mode list fills in a moment after the display appears; then pick the mode and
        // start mirroring in one reconfiguration.
        func settle() {
            guard attempt == generation, self.display === display else { return completion(nil) }
            let mode = display.modeNumber(forPointsWide: UInt(want.pointsWide), scale: UInt(want.scale))
            let waited = CACurrentMediaTime() - started
            if mode < 0 && waited < Self.timeout {
                return DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: settle)
            }
            guard mode >= 0 else {
                hostLog("[display] the virtual display never offered \(want.description); using the real screen")
                remove()
                return completion(nil)
            }
            let physical = Self.physicalDisplays()
            guard display.applyModeNumber(mode, mirroring: physical.map { NSNumber(value: $0) }) else {
                hostLog("[display] could not switch to the virtual display; using the real screen")
                remove()
                return completion(nil)
            }
            mirrored = physical
            // A beat for the window server and ScreenCaptureKit to see the new arrangement.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, attempt == self.generation, self.display === display else { return completion(nil) }
                hostLog(String(format: "[display] virtual display %@ for %@, ready in %.2f s (%d screen(s) mirror it)",
                               want.description, device.name, CACurrentMediaTime() - started, physical.count))
                completion(display.displayID)
                // For testing what a session does when the display vanishes under it.
                if let seconds = ProcessInfo.processInfo.environment["JUMP_VIRTUAL_DISPLAY_DROP_AFTER"].flatMap(Double.init) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                        guard let self, self.display === display else { return }
                        hostLog("[display] test: dropping the virtual display mid-session")
                        self.remove()
                    }
                }
            }
        }
        settle()
    }

    /// The session is over: keep the display a while for a reconnect, then put the Mac back.
    func sessionEnded() {
        guard display != nil else { return }
        removal?.cancel()
        let work = DispatchWorkItem { [weak self] in
            hostLog("[display] no viewer for \(Int(Self.keepAfterSession)) s: removing the virtual display")
            self?.remove()
        }
        removal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.keepAfterSession, execute: work)
    }

    /// Puts the Mac's screens back the way they were, now.
    func remove() {
        removal?.cancel()
        removal = nil
        generation += 1
        guard display != nil else { return }
        // Hand the picture back first, so the real screen is the main one before ours goes.
        JumpVirtualDisplay.stopMirroring(mirrored.map { NSNumber(value: $0) })
        mirrored = []
        display = nil
        size = nil
    }

    /// macOS took the display away (it shouldn't): forget it; a running session's capture stops
    /// and restarts on the real screen.
    private func terminated() {
        hostLog("[display] macOS removed the virtual display")
        generation += 1
        mirrored = []
        display = nil
        size = nil
    }

    /// The Mac's real screens: every online display that isn't one of ours (told by the vendor
    /// number the bridge gives them, so a display just removed can't be mistaken for one).
    private static func physicalDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { CGDisplayVendorNumber($0) != JumpVirtualDisplay.vendorID }
    }
}
