import AppKit

/// Ensures only one MicDownmix process ever runs.
///
/// Two instances would each open the interface and each write to the virtual device, summing two
/// copies of the same audio into one ring buffer. That is corruption, not redundancy.
///
/// The guarantee belongs here rather than in the launch scripts: the app can be started by
/// LaunchServices, by the login agent, or from a terminal, and any pair of those can overlap.
enum SingleInstance {

    /// Exits immediately if another instance is already running.
    ///
    /// When two processes start close enough together to see each other, the one that launched later
    /// yields, so exactly one survives rather than both deferring.
    static func enforce() {
        let current = NSRunningApplication.current
        guard let identifier = current.bundleIdentifier else { return }

        let others = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == identifier && $0.processIdentifier != current.processIdentifier
        }
        guard !others.isEmpty else { return }

        let myLaunch = current.launchDate ?? .distantFuture
        let anyOlder = others.contains { ($0.launchDate ?? .distantPast) < myLaunch }

        if anyOlder {
            // Exit zero: this is an orderly stand-down, not a crash, so the login agent's
            // KeepAlive rule correctly declines to restart it.
            exit(0)
        }
    }
}
