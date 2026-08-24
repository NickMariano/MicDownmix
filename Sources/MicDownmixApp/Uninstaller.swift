import AppKit
import Foundation

/// Removes every trace of MicDownmix.
///
/// Dragging the app to the Trash is not enough and fails badly: the HAL driver stays installed and
/// keeps publishing a virtual microphone that nothing drives, so a dead input device sits in every
/// app's list forever, and the login agent keeps pointing at a binary that no longer exists.
enum Uninstaller {

    static let driverPath = "/Library/Audio/Plug-Ins/HAL/MicDownmixDriver.driver"
    static let appPath = "/Applications/MicDownmix.app"
    static let receiptID = "com.stealthpyro.MicDownmix.installer"

    /// Asks, removes everything, then quits.
    static func run() {
        let alert = NSAlert()
        alert.messageText = "Uninstall MicDownmix?"
        alert.informativeText = """
        This removes the app, its audio driver, and its login item.

        Audio will cut out for about a second while macOS unloads the driver. Anything currently \
        using MicDownmix as its microphone will need a different input selected.
        """
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // User-level things first: no authorisation needed, and doing them before the privileged
        // step means a cancelled password prompt still leaves the login agent gone rather than
        // pointing at an app that is about to vanish.
        removeUserLevelParts()

        do {
            try removePrivilegedParts()
        } catch DriverError.cancelled {
            let cancelled = NSAlert()
            cancelled.messageText = "Uninstall cancelled"
            cancelled.informativeText = """
            The login item and settings were removed, but the audio driver and the app are still \
            installed. Run Uninstall again to finish.
            """
            cancelled.runModal()
            return
        } catch {
            let failure = NSAlert()
            failure.messageText = "Could not finish uninstalling"
            failure.informativeText = error.localizedDescription
            failure.alertStyle = .warning
            failure.runModal()
            return
        }

        NSApp.terminate(nil)
    }

    static func removeUserLevelParts() {
        let manager = FileManager.default

        try? LoginItem.setEnabled(false)
        LoginItem.removeLegacyAgentIfPresent()

        let defaults = Process()
        defaults.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        defaults.arguments = ["delete", "com.stealthpyro.MicDownmix"]
        defaults.standardError = Pipe()
        try? defaults.run()
        defaults.waitUntilExit()
    }

    /// The driver, the app bundle and the installer receipt, behind one authorisation.
    ///
    /// The app deletes itself last and the whole thing is backgrounded, so the shell survives this
    /// process exiting and can finish removing the bundle it is running from.
    static func removePrivilegedParts() throws {
        var steps: [String] = []
        if FileManager.default.fileExists(atPath: driverPath) { steps.append("rm -rf '\(driverPath)'") }
        steps.append("pkgutil --forget \(receiptID) >/dev/null 2>&1 || true")
        steps.append("killall coreaudiod 2>/dev/null || true")
        if FileManager.default.fileExists(atPath: appPath) { steps.append("rm -rf '\(appPath)'") }

        try DriverInstaller.runPrivileged(steps.joined(separator: "; "),
                                          describing: "uninstall MicDownmix")
    }
}
