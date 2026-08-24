import AppKit

/// Deep links into the exact System Settings pane a declined permission lives in.
///
/// macOS will not re-prompt for microphone access once it has been denied, so "try again" is not an
/// option the app can offer. Taking someone straight to the switch is the only real recovery.
enum SystemSettings {

    enum Pane {
        case microphone
        case loginItems

        var url: URL? {
            switch self {
            case .microphone:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            case .loginItems:
                return URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
            }
        }

        /// What to actually do once the pane is open. Shown alongside the button, because the pane
        /// opens to a list and the relevant row is not always obvious.
        var instructions: String {
            switch self {
            case .microphone:
                return "Find MicDownmix in the list and turn it on. If it is not listed, quit and reopen MicDownmix first."
            case .loginItems:
                return "Under \"Allow in the Background\", turn on MicDownmix."
            }
        }
    }

    static func open(_ pane: Pane) {
        guard let url = pane.url else { return }
        NSWorkspace.shared.open(url)
    }
}
