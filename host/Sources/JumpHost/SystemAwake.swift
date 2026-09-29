import Foundation
import IOKit.pwr_mgt
import QuartzCore

/// Keeps the Mac's display on while a client is watching it.
enum SystemAwake {
    private static var displayAssertion = IOPMAssertionID(0)
    private static var activityAssertion = IOPMAssertionID(0)
    private static var wakeAssertion = IOPMAssertionID(0)
    private static var lastActivity: CFTimeInterval = 0

    /// Call on the host queue when a session connects.
    static func hold() {
        guard displayAssertion == 0 else { return }
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "Jump remote session" as CFString,
                                    &displayAssertion)
    }

    /// Wakes a sleeping display so capture has something to show before the first input.
    /// Call on the host queue when a session starts.
    static func wakeDisplay() {
        IOPMAssertionDeclareUserActivity("Jump remote session" as CFString, kIOPMUserActiveLocal, &wakeAssertion)
    }

    /// Call on the host queue when the session ends.
    static func release() {
        guard displayAssertion != 0 else { return }
        IOPMAssertionRelease(displayAssertion)
        displayAssertion = 0
    }

    /// Remote input counts as the user being present: wakes a dimmed display and holds off
    /// the screen saver and lock. Throttled; call from the input thread only.
    static func noteUserActivity() {
        let now = CACurrentMediaTime()
        guard now - lastActivity > 5 else { return }
        lastActivity = now
        IOPMAssertionDeclareUserActivity("Jump remote input" as CFString, kIOPMUserActiveLocal, &activityAssertion)
    }
}
