import Foundation
import ServiceManagement

/// Starts Wherever Host at login and again after a crash: a LaunchAgent in ~/Library/LaunchAgents
/// (KeepAlive unless it exits cleanly, so quitting from the menu stays quit).
///
/// A plain agent plist, not SMAppService.agent: without a Team ID macOS ties an SMAppService
/// registration to the exact build, and after every update launchd refused to start the new
/// binary ("Launch Constraint Violation"). This one names the executable by path.
enum LoginAgent {
    static let label = "com.jihun.jumphost.agent"
    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    private static var domain: String { "gui/\(getuid())" }

    /// This process was started by the agent (launchd names its job in XPC_SERVICE_NAME).
    static var isCurrentProcess: Bool { ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label }
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) && isLoaded }
    /// Turned on, but launchd doesn't have it (e.g. switched off under System Settings → Login Items).
    static var needsApproval: Bool { FileManager.default.fileExists(atPath: plistURL.path) && !isLoaded }
    private static var isLoaded: Bool { launchctl(["print", "\(domain)/\(label)"]) == 0 }

    /// Test instances and copies run straight from a download (translocated) never register.
    private static var eligible: Bool {
        ProcessInfo.processInfo.environment["JUMP_DEFAULTS_SUITE"] == nil
            && Bundle.main.bundlePath.hasSuffix(".app")
            && !Bundle.main.bundlePath.contains("/AppTranslocation/")
    }

    private static var definition: [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [Bundle.main.executablePath ?? ""],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 10,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            // Lets the app hand over to a fresh copy when the agent is turned off from its menu.
            "AbandonProcessGroup": true,
        ]
    }

    /// Installs or removes the agent to match `HostConfig.launchAtLogin`. Returns the error, if any.
    @discardableResult
    static func apply() -> Error? {
        guard eligible else { return nil }
        // Earlier versions used the plain login item, and a 0.8.7 build briefly SMAppService.agent.
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
        let bundled = SMAppService.agent(plistName: "\(label).plist")
        if bundled.status == .enabled || bundled.status == .requiresApproval { try? bundled.unregister() }

        do {
            if HostConfig.shared.launchAtLogin {
                let data = try PropertyListSerialization.data(fromPropertyList: definition, format: .xml, options: 0)
                let changed = (try? Data(contentsOf: plistURL)) != data
                if changed {
                    try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    try data.write(to: plistURL, options: .atomic)
                }
                guard changed || !isLoaded else { return nil }
                // The job of this very process can't be reloaded without stopping it; the new
                // file applies from the next login then.
                if isLoaded {
                    guard !isCurrentProcess else { return nil }
                    _ = launchctl(["bootout", "\(domain)/\(label)"])
                }
                // Starts a second copy right away (RunAtLoad); it finds this one and quits.
                let status = launchctl(["bootstrap", domain, plistURL.path])
                hostLog("[app] login agent installed (launchctl \(status))")
                if status != 0 { throw NSError(domain: "JumpHost", code: Int(status), userInfo: [
                    NSLocalizedDescriptionKey: "launchctl bootstrap failed (\(status))"]) }
            } else {
                guard FileManager.default.fileExists(atPath: plistURL.path) else { return nil }
                if isCurrentProcess { relaunchAfterRemoval() }
                try? FileManager.default.removeItem(at: plistURL)
                _ = launchctl(["bootout", "\(domain)/\(label)"]) // stops this process when it is the agent's
                hostLog("[app] login agent removed")
            }
            return nil
        } catch {
            hostLog("[app] login agent: \(error)")
            return error
        }
    }

    /// Opened by hand (Finder, Spotlight, after an update) while the agent is on: let launchd
    /// run Wherever Host instead, so a crash later on is restarted too. True when this copy should
    /// quit now: launchd starts the other a second later, and if it didn't after all, this app
    /// reopens the ordinary way.
    static func handOverIfNeeded() -> Bool {
        guard eligible, !isCurrentProcess, HostConfig.shared.launchAtLogin, isEnabled, startsThisCopy,
              ProcessInfo.processInfo.environment["JUMP_NO_HANDOVER"] == nil
        else { return false }
        // launchd holds back a job that exited less than ThrottleInterval (10 s) ago, e.g. one
        // just quit for an update: wait that out before falling back, or both copies start.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", "sleep 1; /bin/launchctl kickstart \"gui/$(id -u)/$1\";"
                + " for i in $(/usr/bin/seq 15); do sleep 1; /usr/bin/pgrep -x JumpHost >/dev/null && exit 0; done;"
                + " /usr/bin/open -n --env JUMP_NO_HANDOVER=1 \"$0\"",
            Bundle.main.bundlePath, label,
        ]
        do { try process.run() } catch { return false }
        hostLog("[app] opened by hand: handing over to the login agent")
        return true
    }

    /// The agent runs this very app. Not after the app moved or was renamed (JumpHost.app became
    /// WhereverHost.app): handing over then would start the old path, so this copy carries on
    /// and `apply()` points the agent here first.
    private static var startsThisCopy: Bool {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String]
        else { return false }
        return arguments.first == Bundle.main.executablePath
    }

    /// Removing the agent stops the process it started, i.e. this one: start a fresh copy a
    /// moment later (AbandonProcessGroup lets the helper outlive this process).
    private static func relaunchAfterRemoval() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 3; /usr/bin/open --env JUMP_NO_HANDOVER=1 \"$0\"", Bundle.main.bundlePath]
        try? process.run()
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
