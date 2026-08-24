import SwiftUI

/// The guided setup. Shown automatically until everything is green, and reachable from the menu
/// afterwards so a permission revoked later can still be fixed.
struct SetupView: View {
    @ObservedObject var model: SetupModel
    var onFinish: () -> Void

    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            VStack(spacing: 0) {
                ForEach(Array(model.visibleSteps.enumerated()), id: \.element) { index, step in
                    if index > 0 { Divider().padding(.leading, 44) }
                    StepRow(
                        step: step,
                        status: model.statuses[step] ?? .needsAction(detail: ""),
                        isBusy: model.busyStep == step,
                        perform: { model.perform(step, confirmAudioInterruption: confirmAudioInterruption) }
                    )
                }
            }

            if let message = model.errorMessage {
                Divider()
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(14)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            footer
        }
        .frame(width: 520)
        // Re-derive on focus, so switching to System Settings and back updates without a click.
        .onChange(of: activeState) { _, newValue in
            if newValue != .inactive { model.refresh() }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "mic.badge.plus")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("Set up MicDownmix")
                    .font(.title3.weight(.semibold))
                Text(model.isComplete
                     ? "Everything is ready. Pick your interface and channel from the menu bar."
                     : "\(model.outstandingCount) thing\(model.outstandingCount == 1 ? "" : "s") left to do.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Button("Re-check") { model.refresh() }
            Spacer()
            Button(model.isComplete ? "Done" : "Continue Anyway") { onFinish() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    /// Installing or removing a driver restarts coreaudiod, which cuts all audio on the machine for
    /// a second. Saying so beforehand is the difference between a brief glitch and a panic.
    private func confirmAudioInterruption() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Audio will cut out briefly"
        alert.informativeText = """
        macOS has to restart its audio service to load or unload a driver. Every app playing or \
        recording audio will glitch for about a second.

        If you are in a call right now, do this afterwards.
        """
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }
}

private struct StepRow: View {
    let step: SetupStep
    let status: StepStatus
    let isBusy: Bool
    let perform: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon
                .frame(width: 20)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(step.title)
                    .font(.body.weight(.medium))
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // A blocked step cannot be retried in place, so it gets the route that does work.
                if case .blocked = status, let pane = step.settingsPane {
                    Text(pane.instructions)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 1)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open System Settings") { SystemSettings.open(pane) }
                        .controlSize(.small)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 8)

            if isBusy {
                ProgressView().controlSize(.small)
            } else if !status.isSatisfied, !isBlocked {
                Button(step.actionLabel, action: perform)
                    .controlSize(.small)
            }
        }
        .padding(14)
    }

    private var isBlocked: Bool { if case .blocked = status { return true }; return false }

    private var icon: some View {
        Group {
            switch status {
            case .satisfied:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .needsAction:
                Image(systemName: "circle.dashed").foregroundStyle(.secondary)
            case .blocked:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            }
        }
        .font(.system(size: 16))
    }
}

import AppKit

/// Hosts the setup view in a real window. A menu bar app has no windows of its own, so one is made
/// on demand and reused.
@MainActor
final class SetupWindowController {
    private var window: NSWindow?
    private let model: SetupModel

    init(model: SetupModel) { self.model = model }

    func show() {
        model.refresh()

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: SetupView(model: model, onFinish: { [weak self] in
            self?.close()
        }))
        let window = NSWindow(contentViewController: hosting)
        window.title = "MicDownmix Setup"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }
}
