import AppKit
import SwiftUI

/// A menu bar app: it has to stay running for the virtual mic to carry audio, so it stays out of the
/// Dock and the window list while it does.
@main
struct MicDownmixApp: App {
    @StateObject private var state = AppState()
    @StateObject private var setup = SetupModel()
    @StateObject private var updates = UpdateChecker()
    @State private var setupController: SetupWindowController?

    init() {
        // A headless report of what setup would show. Exists so the flow can be checked without
        // putting modal dialogs on someone's screen, including in CI.
        if CommandLine.arguments.contains("--setup-check") {
            MainActor.assumeIsolated {
                let model = SetupModel()
                print("MicDownmix setup status")
                print("  bundle: \(Bundle.main.bundlePath)")
                print("  quarantined: \(MoveToApplications.isQuarantined)")
                for step in model.visibleSteps {
                    let status = model.statuses[step] ?? .needsAction(detail: "unknown")
                    let mark: String
                    switch status {
                    case .satisfied: mark = "ok  "
                    case .needsAction: mark = "todo"
                    case .blocked: mark = "BLOCK"
                    }
                    print("  \(mark) \(step.title): \(status.detail)")
                }
                print(model.isComplete ? "complete" : "\(model.outstandingCount) outstanding")
            }
            exit(0)
        }

        // Before anything opens a device or installs anything.
        SingleInstance.enforce()
    }

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("MicDownmix", systemImage: menuBarSymbol) {
            ContentView(state: state, meters: state.meters, updates: updates, openSetup: openSetup)
                .task {
                    // Setup opens itself whenever anything is outstanding, on every launch, not
                    // just the first. A permission revoked months later resurfaces the same way.
                    appDelegate.onLaunch = { Task { @MainActor in firstRun() } }
                    firstRun()
                }
        }
        .menuBarExtraStyle(.window)
    }

    /// The icon carries the state: a warning while setup is incomplete, a badge when an update is
    /// waiting, otherwise whether the mic is actually live.
    ///
    /// The update badge matters because the daily check is silent. Without it the only place a new
    /// version appears is inside a panel that has to be opened deliberately, so in practice nobody
    /// would ever see one. A badge needs no notification permission and nags no one.
    private var menuBarSymbol: String {
        if !setup.isComplete { return "mic.badge.xmark" }
        if case .available = updates.state { return "mic.badge.plus" }
        return state.isRunning ? "mic.fill" : "mic.slash"
    }

    /// Ask for the microphone straight away, then show setup only if a person is actually needed.
    @MainActor
    private func firstRun() {
        setup.requestMicrophoneIfUndecided()
        setup.refresh()
        updates.checkIfDue()
        if setup.needsAttention { openSetup() }
    }

    @MainActor
    private func openSetup() {
        if setupController == nil {
            setupController = SetupWindowController(model: setup)
        }
        setupController?.show()
    }
}

/// Runs the first-launch relocation prompt and opens setup when anything is outstanding.
///
/// This lives in an AppDelegate rather than in `App.init` because both need a running NSApplication:
/// a modal alert before `applicationDidFinishLaunching` appears behind everything else.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onLaunch: (() -> Void)?

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { launch() }
    }

    private func launch() {
        // If this relaunches from /Applications, the process exits here and the copy takes over.
        if MoveToApplications.offerIfNeeded() { return }
        onLaunch?()
    }
}
