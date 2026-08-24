import AppKit

/// Offers to relocate the app to /Applications on first launch, and detects Gatekeeper quarantine.
///
/// Running from a mounted disk image or the Downloads folder breaks things in ways that are hard to
/// diagnose later: the login agent would point at a path that disappears when the image is ejected,
/// and the driver would be installed from a bundle that is about to vanish.
enum MoveToApplications {

    static let destination = "/Applications/MicDownmix.app"

    static var currentPath: String { Bundle.main.bundlePath }

    static var isInApplications: Bool {
        currentPath == destination
    }

    static var isOnReadOnlyVolume: Bool {
        // A mounted DMG. Worth naming explicitly, because "move" is the only sane option there.
        (try? URL(fileURLWithPath: currentPath)
            .resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true
    }

    /// True when the bundle still carries the quarantine flag, which is what produces the
    /// "damaged and can't be opened" dialog on an ad-hoc signed download.
    static var isQuarantined: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-p", "com.apple.quarantine", currentPath]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Asks, moves, and relaunches. Returns true if a relaunch was started, in which case the caller
    /// should stop doing anything else.
    /// The version of the copy already installed in /Applications, if there is one.
    private static var installedVersion: String? {
        let plist = "\(destination)/Contents/Info.plist"
        guard let data = FileManager.default.contents(atPath: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = object as? [String: Any] else { return nil }
        return dictionary["CFBundleVersion"] as? String
    }

    private static var ownVersion: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
    }

    /// Hands off to the installed copy if this process is a stray duplicate.
    ///
    /// There is deliberately no "move me to Applications" prompt. The installer package puts the app
    /// in /Applications, so a copy running from anywhere else is a leftover download or something
    /// Spotlight turned up, never the real install. Asking the user to relocate it made them answer
    /// a question that only existed because of an older packaging choice.
    ///
    /// Returns true if this process is standing down, in which case the caller must do nothing else.
    @discardableResult
    static func offerIfNeeded() -> Bool {
        guard !isInApplications else { return false }

        if FileManager.default.fileExists(atPath: destination) {
            handOffToInstalledCopy()
            return true
        }

        // Nothing installed at all: the app is being run outside the installer, which is a developer
        // scenario. Carry on rather than blocking, but say so.
        NSLog("MicDownmix: running from \(currentPath), not /Applications. Install the package for the supported setup.")
        return false
    }

    /// Starts the installed copy and exits.
    ///
    /// The launch is detached and delayed rather than immediate: the replacement process checks for
    /// an existing instance on startup, and if this one were still alive it would see it, conclude
    /// it is the duplicate, and stand down. Both would then be gone, which is exactly the "clicked
    /// it and nothing happened" symptom.
    private static func handOffToInstalledCopy() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; open -a '\(destination)'"]
        try? process.run()
        exit(0)
    }

}
