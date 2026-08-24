import AVFoundation
import Foundation
import SwiftUI

/// The state of one thing that has to be true before MicDownmix can work.
enum StepStatus: Equatable {
    case satisfied(detail: String)
    case needsAction(detail: String)
    /// Refused, and macOS will not ask again. Recovery is a trip to System Settings.
    case blocked(detail: String)

    var isSatisfied: Bool { if case .satisfied = self { return true }; return false }

    var detail: String {
        switch self {
        case let .satisfied(detail), let .needsAction(detail), let .blocked(detail): return detail
        }
    }
}

enum SetupStep: String, CaseIterable, Identifiable {
    case driver
    case microphone
    case launchAtLogin
    case legacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .driver: return "Audio driver"
        case .microphone: return "Microphone access"
        case .launchAtLogin: return "Start at login"
        case .legacy: return "Remove previous version"
        }
    }

    var actionLabel: String {
        switch self {
        case .driver: return "Install"
        case .microphone: return "Allow"
        case .launchAtLogin: return "Enable"
        case .legacy: return "Remove"
        }
    }

    /// Steps that are only worth showing when they actually apply.
    var isConditional: Bool { self == .legacy || self == .microphone }

    var settingsPane: SystemSettings.Pane? {
        switch self {
        case .microphone: return .microphone
        case .launchAtLogin: return .loginItems
        default: return nil
        }
    }

    /// Whether acting on this step interrupts audio playback machine-wide.
    var interruptsAudio: Bool {
        self == .driver || self == .legacy
    }
}

/// Derives every step's state from the real system, never from a record of having asked.
///
/// This matters because macOS refuses to re-prompt for microphone access after a denial. A flag
/// saying "we already requested this" would leave someone permanently stuck with no way forward, so
/// the model re-reads actual state every time and offers a settings deep link when it is blocked.
@MainActor
final class SetupModel: ObservableObject {

    @Published private(set) var statuses: [SetupStep: StepStatus] = [:]
    @Published private(set) var busyStep: SetupStep?
    @Published var errorMessage: String?

    /// Steps that apply right now, in the order they should be done.
    var visibleSteps: [SetupStep] {
        SetupStep.allCases.filter { step in
            guard step.isConditional else { return true }
            switch step {
            case .legacy: return LegacyCleanup.isPresent
            // Only when macOS has actually denied it; see refresh().
            case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .denied
                || AVCaptureDevice.authorizationStatus(for: .audio) == .restricted
            default: return true
            }
        }
    }

    var isComplete: Bool {
        visibleSteps.allSatisfy { statuses[$0]?.isSatisfied ?? false }
    }

    var outstandingCount: Int {
        visibleSteps.filter { !(statuses[$0]?.isSatisfied ?? false) }.count
    }

    init() {
        applyFirstRunDefaults()
        refresh()
    }

    /// Turns on start-at-login the first time the app runs after being installed.
    ///
    /// Running an installer is a clear enough statement of intent that asking again is friction for
    /// its own sake, and without it the microphone is silent after every reboot until the app is
    /// opened by hand. It stays a visible, reversible switch in setup.
    private func applyFirstRunDefaults() {
        let key = "didApplyFirstRunDefaults"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        guard MoveToApplications.isInApplications, !LoginItem.isEnabled else { return }
        try? LoginItem.setEnabled(true)
    }

    /// Whether the setup window is worth showing at all.
    ///
    /// Only when something actually needs a person. A window that opens to say everything is fine is
    /// just another thing to dismiss.
    var needsAttention: Bool { !isComplete }

    /// Asks for microphone access if it has never been decided, so the standard prompt appears on
    /// its own instead of hiding behind a button in a window that may not even open.
    func requestMicrophoneIfUndecided() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    func refresh() {
        var next: [SetupStep: StepStatus] = [:]

        switch DriverInstaller.state() {
        case .notInstalled:
            next[.driver] = .needsAction(detail: LegacyCleanup.isPresent
                ? "Installs the driver and removes the previous version at the same time, so audio only cuts out once."
                : "The virtual microphone does not exist until the driver is installed.")
        case let .outdated(installed, available):
            next[.driver] = .needsAction(detail: "Version \(installed) is installed; this app ships \(available).")
        case let .current(version):
            next[.driver] = .satisfied(detail: "Version \(version) installed.")
        }

        // Access is always requested on launch, but the step is only *shown* once macOS has denied
        // it. Whether a prompt appears at all varies: this app is not sandboxed and reads the
        // interface through CoreAudio's HAL, and TCC attributes such access to the responsible
        // process, so on some systems no prompt is raised and the app never appears under Privacy &
        // Security at all. Showing a green tick in that case sends people hunting through System
        // Settings for an entry that does not exist, so nothing is claimed either way unless macOS
        // has actually refused.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            next[.microphone] = .satisfied(detail: "Granted.")
        case .notDetermined:
            next[.microphone] = .satisfied(detail: "Not requested by macOS on this system.")
        default:
            next[.microphone] = .blocked(detail: "Denied. Turn MicDownmix back on under Privacy & Security > Microphone.")
        }

        if LoginItem.isEnabled {
            next[.launchAtLogin] = .satisfied(detail: "MicDownmix starts automatically.")
        } else if LoginItem.isBlockedByUser {
            next[.launchAtLogin] = .blocked(detail: "Turned off in System Settings. Re-registering it here would silently do nothing.")
        } else {
            next[.launchAtLogin] = .needsAction(detail: "Without this the microphone is silent until you open MicDownmix.")
        }

        next[.legacy] = LegacyCleanup.isPresent
            ? .needsAction(detail: "An earlier version is installed and publishes a second, similar looking microphone.")
            : .satisfied(detail: "Nothing left to clean up.")

        statuses = next
    }

    /// Performs a step. `confirmAudioInterruption` is called first for steps that restart
    /// coreaudiod, and returning false abandons the action.
    func perform(_ step: SetupStep, confirmAudioInterruption: () -> Bool) {
        if step.interruptsAudio, !confirmAudioInterruption() { return }

        busyStep = step
        errorMessage = nil
        defer { busyStep = nil; refresh() }

        do {
            switch step {
            case .driver:
                // Fold the old install's removal into the same operation: one prompt, one restart.
                LegacyCleanup.removeUserLevelParts()
                try DriverInstaller.install(alsoRemoving: LegacyCleanup.privilegedPaths)
            case .microphone:
                requestMicrophone()
            case .launchAtLogin:
                try LoginItem.setEnabled(true)
            case .legacy:
                try LegacyCleanup.remove()
            }
        } catch {
            // A deliberate cancel reports no message; showing an error for it would be noise.
            if let message = error.localizedDescription as String?, !message.isEmpty,
               (error as? DriverError) != .cancelled {
                errorMessage = message
            }
        }
    }

    private func requestMicrophone() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else {
            // Already decided. Nothing to request; the UI shows the settings route instead.
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            Task { @MainActor in self.refresh() }
        }
    }
}

extension DriverError: Equatable {
    static func == (lhs: DriverError, rhs: DriverError) -> Bool {
        switch (lhs, rhs) {
        case (.cancelled, .cancelled), (.missingFromAppBundle, .missingFromAppBundle): return true
        case let (.failed(a, b), .failed(c, d)): return a == c && b == d
        default: return false
        }
    }
}
