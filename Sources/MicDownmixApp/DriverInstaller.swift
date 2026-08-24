import Foundation

/// Installs, upgrades and removes the HAL plug-in.
///
/// The driver ships inside the app at `Contents/Resources/MicDownmixDriver.driver`, so there is
/// never a second thing to download. Installing needs one administrator authorisation, raised as a
/// native dialog rather than by sending anyone to Terminal.
enum DriverInstaller {

    static let halDirectory = "/Library/Audio/Plug-Ins/HAL"
    static let bundleName = "MicDownmixDriver.driver"
    static var installedPath: String { "\(halDirectory)/\(bundleName)" }

    enum State: Equatable {
        case notInstalled
        case outdated(installed: String, available: String)
        case current(version: String)

        var isUsable: Bool {
            if case .notInstalled = self { return false }
            return true
        }
    }

    /// The copy inside this app bundle.
    static var bundledPath: String? {
        Bundle.main.resourceURL?.appendingPathComponent(bundleName).path
    }

    static func version(ofBundleAt path: String) -> String? {
        let plist = "\(path)/Contents/Info.plist"
        guard let data = FileManager.default.contents(atPath: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = object as? [String: Any] else { return nil }
        return dictionary["CFBundleVersion"] as? String
    }

    static func state() -> State {
        let available = bundledPath.flatMap { version(ofBundleAt: $0) } ?? "1"
        guard FileManager.default.fileExists(atPath: installedPath),
              let installed = version(ofBundleAt: installedPath) else {
            return .notInstalled
        }
        // Compared numerically so that 10 is newer than 9, which a string compare gets wrong.
        let isOlder = (Int(installed) ?? 0) < (Int(available) ?? 0)
        return isOlder ? .outdated(installed: installed, available: available) : .current(version: installed)
    }

    /// Copies the driver into place and restarts coreaudiod, behind a single admin prompt.
    ///
    /// Restarting coreaudiod interrupts all audio on the machine. Callers must warn before calling
    /// this, not after.
    /// - Parameter alsoRemoving: extra bundle paths to delete in the same operation.
    ///
    /// Removing an old driver and installing a new one are folded into one script deliberately.
    /// Each privileged action restarts coreaudiod, so doing them separately means two audio
    /// dropouts and two password prompts for what is, to the person doing it, one job.
    static func install(alsoRemoving legacyPaths: [String] = []) throws {
        guard let source = bundledPath, FileManager.default.fileExists(atPath: source) else {
            throw DriverError.missingFromAppBundle
        }

        var steps = ["mkdir -p '\(halDirectory)'"]
        steps += legacyPaths.map { "rm -rf '\($0)'" }
        steps += [
            "rm -rf '\(installedPath)'",
            "cp -R '\(source)' '\(halDirectory)/'",
            "chown -R root:wheel '\(installedPath)'",
            "killall coreaudiod",
        ]
        try runPrivileged(steps.joined(separator: " && "),
                          describing: "install the MicDownmix audio driver")
    }

    static func uninstall() throws {
        let script = "rm -rf '\(installedPath)' && killall coreaudiod"
        try runPrivileged(script, describing: "remove the MicDownmix audio driver")
    }

    /// Runs a shell script with administrator rights via osascript, which raises the standard
    /// authentication dialog. Cancelling produces error -128, reported as a cancellation rather than
    /// as a failure so the UI does not show an alarming message for a deliberate choice.
    static func runPrivileged(_ script: String, describing purpose: String) throws {
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        // Without an explicit prompt the dialog reads "osascript wants to make changes", naming a
        // scripting tool rather than the app, with no reason given. That is indistinguishable from
        // something malicious asking for a password.
        let reason = "MicDownmix needs your permission to \(purpose)."
            .replacingOccurrences(of: "\"", with: "")
        let appleScript = "do shell script \"\(escaped)\" with prompt \"\(reason)\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = Pipe()

        try process.run()
        let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus != 0 else { return }
        let message = String(decoding: errorData, as: UTF8.self)
        if message.contains("-128") || message.localizedCaseInsensitiveContains("User canceled") {
            throw DriverError.cancelled
        }
        throw DriverError.failed(purpose: purpose, message: message.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

enum DriverError: LocalizedError {
    case missingFromAppBundle
    case cancelled
    case failed(purpose: String, message: String)

    var errorDescription: String? {
        switch self {
        case .missingFromAppBundle:
            return "This copy of MicDownmix is missing its audio driver. Download it again."
        case .cancelled:
            return nil  // A deliberate cancel is not an error worth shouting about.
        case let .failed(purpose, message):
            return "Could not \(purpose). \(message)"
        }
    }
}
