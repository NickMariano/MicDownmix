import Foundation

/// Finds and removes the earlier "MacAudio" build.
///
/// It published its own virtual device, so leaving it installed means two similar looking
/// microphones in every app's input list and two engines competing for the interface.
enum LegacyCleanup {

    static let driverPath = "/Library/Audio/Plug-Ins/HAL/MacAudioDriver.driver"
    static let appPath = "/Applications/MacAudio.app"
    static let agentLabel = "com.stealthpyro.MacAudio.LoginAgent"

    static var agentPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    static var isPresent: Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: driverPath)
            || manager.fileExists(atPath: appPath)
            || manager.fileExists(atPath: agentPlist.path)
    }

    /// The privileged paths, for folding into the driver install so there is only one restart.
    static var privilegedPaths: [String] {
        [driverPath, appPath].filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// The parts that need no authorisation: the login agent, the running app, stale preferences.
    /// Safe to call at any time; it never touches audio.
    static func removeUserLevelParts() {
        let manager = FileManager.default

        let bootout = Process()
        bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootout.arguments = ["bootout", "gui/\(getuid())/\(agentLabel)"]
        try? bootout.run()
        bootout.waitUntilExit()
        try? manager.removeItem(at: agentPlist)

        for app in NSWorkspaceRunningMacAudioApps() {
            app.terminate()
        }

        let defaults = Process()
        defaults.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        defaults.arguments = ["delete", "com.stealthpyro.MacAudio"]
        defaults.standardError = Pipe()
        try? defaults.run()
        defaults.waitUntilExit()
    }

    /// Removes the user-level parts without any prompt, then the privileged parts behind one
    /// authorisation. The driver removal restarts coreaudiod, so callers must warn first.
    static func remove() throws {
        let manager = FileManager.default

        // Stop and forget the old login agent.
        let bootout = Process()
        bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootout.arguments = ["bootout", "gui/\(getuid())/\(agentLabel)"]
        try? bootout.run()
        bootout.waitUntilExit()
        try? manager.removeItem(at: agentPlist)

        for app in NSWorkspaceRunningMacAudioApps() {
            app.terminate()
        }

        // The old preferences domain, so a stale source selection cannot resurface.
        let defaults = Process()
        defaults.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        defaults.arguments = ["delete", "com.stealthpyro.MacAudio"]
        defaults.standardError = Pipe()
        try? defaults.run()
        defaults.waitUntilExit()

        var privileged: [String] = []
        if manager.fileExists(atPath: driverPath) { privileged.append("rm -rf '\(driverPath)'") }
        if manager.fileExists(atPath: appPath) { privileged.append("rm -rf '\(appPath)'") }
        guard !privileged.isEmpty else { return }
        privileged.append("killall coreaudiod")

        try DriverInstaller.runPrivileged(
            privileged.joined(separator: " && "),
            describing: "remove the old MacAudio install"
        )
    }
}

import AppKit

private func NSWorkspaceRunningMacAudioApps() -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.stealthpyro.MacAudio" }
}
