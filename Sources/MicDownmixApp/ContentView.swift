import MicDownmixCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var state: AppState
    @ObservedObject var updates: UpdateChecker
    var openSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()

            if !state.driverInstalled {
                driverMissingNotice
            } else {
                sourcePicker
                channelList
                gainControl
                outputMeter
            }

            if let message = state.errorMessage {
                Divider()
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case let .available(version) = updates.state {
                Divider()
                Button {
                    updates.downloadAndInstall()
                } label: {
                    Label("Version \(version) is available", systemImage: "arrow.down.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.link)
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Text("MicDownmix")
                .font(.headline)
            Spacer()
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // "Live" must not be shown for a configuration that cannot produce sound. A running engine with
    // no channels selected is silent by construction, and saying so is the difference between a
    // two-second fix and hunting a phantom driver bug.
    private var statusColor: Color {
        if state.isSilentByConfiguration { return .orange }
        if let device = state.selectedDevice, !device.supportsRequiredSampleRate { return .orange }
        return state.isRunning ? .green : Color.secondary.opacity(0.4)
    }

    private var statusText: String {
        if state.isSilentByConfiguration { return "No channels" }
        if let device = state.selectedDevice, !device.supportsRequiredSampleRate { return "Wrong rate" }
        return state.isRunning ? "Live" : "Stopped"
    }

    private var driverMissingNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Driver not installed", systemImage: "externaldrive.badge.xmark")
                .font(.subheadline.weight(.medium))
            Text("The virtual microphone does not exist yet. Setup installs it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open Setup", action: openSetup)
                .controlSize(.small)
        }
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Source")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Source", selection: Binding(
                get: { state.selectedUID ?? "" },
                set: { state.selectedUID = $0.isEmpty ? nil : $0 }
            )) {
                ForEach(state.devices) { device in
                    Text("\(device.name) (\(device.inputChannelCount) ch)").tag(device.uid)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            if let device = state.selectedDevice, !device.supportsRequiredSampleRate {
                // Says outright that it is not running. An orange note about sample rates alongside
                // an otherwise normal looking panel reads as a warning, not as a refusal, and the
                // user is left thinking it started.
                VStack(alignment: .leading, spacing: 3) {
                    Label("Not running", systemImage: "exclamationmark.octagon.fill")
                        .font(.caption.weight(.semibold))
                    Text("This device runs at \(Int(device.sampleRate)) Hz, which MicDownmix does not support. Pick a different input, or change its rate in Audio MIDI Setup.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.orange)
                .padding(.top, 2)
            }
        }
    }

    private var channelList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Channels")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("summed to mono")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if state.displayChannelCount == 0 {
                Text("Select a source to choose channels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                if state.selectedChannels == 0 {
                    Label("No channels selected, so the mic is silent. Tick the one your voice appears on.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The height is explicit. A ScrollView inside a self-sizing MenuBarExtra window has
                // no intrinsic height to claim and collapses to nothing, which hides the entire
                // channel list while leaving the rest of the panel looking correct.
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(0..<state.displayChannelCount, id: \.self) { channel in
                            ChannelRow(
                                index: channel,
                                isSelected: state.isChannelSelected(channel),
                                level: channel < state.channelPeaks.count ? state.channelPeaks[channel] : 0,
                                toggle: { state.setChannel(channel, selected: !state.isChannelSelected(channel)) }
                            )
                        }
                    }
                    .padding(.trailing, 2)
                }
                .frame(height: Self.channelListHeight(for: state.displayChannelCount))
            }
        }
    }

    /// Rows are a fixed height, so the list shows up to eight at a time and scrolls beyond that.
    private static func channelListHeight(for count: Int) -> CGFloat {
        let rowHeight: CGFloat = 22
        return CGFloat(min(max(count, 1), 8)) * rowHeight
    }

    private var gainControl: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Gain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.2f×", state.gain))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $state.gain, in: 0...4)
        }
    }

    private var outputMeter: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Output")
                .font(.caption)
                .foregroundStyle(.secondary)
            LevelBar(level: state.outputPeak, height: 6)
        }
    }

    @ViewBuilder
    private var updateItems: some View {
        switch updates.state {
        case .checking:
            Text("Checking for updates...")
        case .downloading:
            Text("Downloading update...")
        case let .available(version):
            Button("Install Update \(version)...") { updates.downloadAndInstall() }
            Button("What's New in \(version)") { updates.openReleasePage() }
        case .upToDate:
            Text("MicDownmix \(updates.currentVersion) is up to date")
            Button("Check Again") { updates.check(userInitiated: true) }
        case let .failed(message):
            Text("Update check failed: \(message)")
            Button("Try Again") { updates.check(userInitiated: true) }
        case .idle:
            Button("Check for Updates...") { updates.check(userInitiated: true) }
        }
    }

    private var loginItemToggle: some View {
        Toggle(isOn: $state.launchAtLogin) {
            Text("Start at login")
                .font(.caption)
        }
        .toggleStyle(.checkbox)
        .disabled(!state.canLaunchAtLogin)
        .help(state.canLaunchAtLogin
              ? "Runs MicDownmix automatically when you log in."
              : "Available once the app is installed in /Applications.")
    }

    private var footer: some View {
        HStack {
            Button(state.isRunning ? "Stop" : "Start") { state.toggleRunning() }
                .disabled(!state.driverInstalled || state.selectedUID == nil)
            Button("Setup", action: openSetup)
            Spacer()
            Menu {
                updateItems
                Divider()
                Button("Uninstall MicDownmix...") { Uninstaller.run() }
                Divider()
                Button("Quit MicDownmix") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

private struct ChannelRow: View {
    let index: Int
    let isSelected: Bool
    let level: Float
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { isSelected }, set: { _ in toggle() })) {
                Text("Ch \(index + 1)")
                    .font(.caption.monospacedDigit())
                    .frame(width: 40, alignment: .leading)
            }
            .toggleStyle(.checkbox)

            LevelBar(level: level, height: 5)
        }
        .frame(height: 20)
    }
}

/// A peak meter on a decibel scale, because a linear one leaves speech hugging the left edge and
/// makes it impossible to tell which channel is actually carrying the voice.
private struct LevelBar: View {
    let level: Float
    var height: CGFloat = 6

    private var fraction: CGFloat {
        guard level > 0 else { return 0 }
        let decibels = 20 * log10(Double(level))
        let floor = -60.0
        return CGFloat(max(0, min(1, (decibels - floor) / -floor)))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(level >= 0.999 ? Color.red : Color.accentColor)
                    .frame(width: max(0, geometry.size.width * fraction))
            }
        }
        .frame(height: height)
    }
}
