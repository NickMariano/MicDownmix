import Foundation
import ServiceManagement

/// Starts MicDownmix at login.
///
/// Uses `SMAppService`, which registers the app itself as a login item. The alternative, writing a
/// LaunchAgent plist by hand, works but macOS attributes it to the signing certificate: the
/// Background Task Management notification then reads "Software from <developer name>" and the
/// entry in Login Items is anonymous. Registering through SMAppService names the app instead, which
/// is both clearer to the user and less revealing of whoever signed it.
enum LoginItem {

    /// Retained so an upgrade can clean up the LaunchAgent earlier versions installed by hand.
    static let legacyLabel = "com.stealthpyro.MicDownmix.LoginAgent"

    static var legacyPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(legacyLabel).plist")
    }

    static let installedExecutable = "/Applications/MicDownmix.app/Contents/MacOS/MicDownmix"

    static var isInstalledInApplications: Bool {
        FileManager.default.isExecutableFile(atPath: installedExecutable)
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True when the user has switched it off in System Settings. Re-registering would silently
    /// fail, so the UI has to send them there rather than offering a button that does nothing.
    static var isBlockedByUser: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        removeLegacyAgentIfPresent()

        if enabled {
            guard isInstalledInApplications else { throw LoginItemError.notInstalled }
            do {
                try SMAppService.mainApp.register()
            } catch {
                // requiresApproval is not a failure: the registration stands, the user simply has to
                // allow it in System Settings.
                if SMAppService.mainApp.status != .requiresApproval {
                    throw LoginItemError.registration(error.localizedDescription)
                }
            }
        } else {
            try? SMAppService.mainApp.unregister()
        }
    }

    /// Removes the hand-written LaunchAgent that earlier versions installed, so an upgraded install
    /// does not end up starting twice.
    static func removeLegacyAgentIfPresent() {
        guard FileManager.default.fileExists(atPath: legacyPlistURL.path) else { return }

        let bootout = Process()
        bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootout.arguments = ["bootout", "gui/\(getuid())/\(legacyLabel)"]
        try? bootout.run()
        bootout.waitUntilExit()
        try? FileManager.default.removeItem(at: legacyPlistURL)
    }
}

enum LoginItemError: LocalizedError {
    case notInstalled
    case registration(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Install MicDownmix to /Applications first."
        case let .registration(message):
            return "Could not enable start at login: \(message)"
        }
    }
}
