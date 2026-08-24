import AVFoundation
import Combine
import CoreAudio
import Foundation
import MicDownmixCore

/// Everything the menu bar UI binds to, and the owner of the engine's lifecycle.
@MainActor
final class AppState: ObservableObject {

    @Published private(set) var devices: [AudioInputDevice] = []
    @Published private(set) var driverInstalled = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRunning = false
    @Published private(set) var channelPeaks: [Float] = []
    @Published private(set) var outputPeak: Float = 0
    @Published private(set) var underruns = 0

    /// Mirrors the LaunchAgent on disk rather than a stored preference, so the toggle always reflects
    /// reality even if the agent is removed with launchctl behind the app's back.
    @Published var launchAtLogin = false {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                try LoginItem.setEnabled(launchAtLogin)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
                // Snap back so the switch cannot claim a state that was never achieved.
                if launchAtLogin != LoginItem.isEnabled {
                    launchAtLogin = LoginItem.isEnabled
                }
            }
        }
    }

    var canLaunchAtLogin: Bool { LoginItem.isInstalledInApplications }

    @Published var selectedUID: String? {
        didSet {
            guard selectedUID != oldValue else { return }
            defaults.set(selectedUID, forKey: Keys.selectedUID)
            restart()
        }
    }

    @Published var selectedChannels: UInt32 = 0 {
        didSet {
            guard selectedChannels != oldValue else { return }
            defaults.set(Int(selectedChannels), forKey: Keys.selectedChannels)
            engine.selectedChannels = selectedChannels
        }
    }

    @Published var gain: Double = 1.0 {
        didSet {
            guard gain != oldValue else { return }
            defaults.set(gain, forKey: Keys.gain)
            engine.gain = gain
        }
    }

    private enum Keys {
        static let selectedUID = "selectedSourceUID"
        static let selectedChannels = "selectedChannels"
        static let gain = "gain"
    }

    private let engine = AudioEngine()
    private let enumerator = DeviceEnumerator()

    /// Every CoreAudio call happens here, never on the main thread.
    ///
    /// HAL property queries and AudioDeviceStart are synchronous IPC to coreaudiod. When coreaudiod
    /// is busy or restarting, which is exactly the situation right after a driver is installed, they
    /// block until it answers. On the main thread that freezes the app, and because every other
    /// audio client is waiting on the same service it presents as a system-wide beachball.
    private let audioQueue = DispatchQueue(label: "com.stealthpyro.MicDownmix.audio", qos: .userInitiated)
    private let defaults = UserDefaults.standard
    private var meterTimer: Timer?
    /// Auto-start is deferred until the device list has loaded, since that now happens off the main
    /// thread and is not finished when init returns.
    private var wantsAutoStart = false
    private var didLoadDevices = false

    var selectedDevice: AudioInputDevice? {
        devices.first { $0.uid == selectedUID }
    }

    var channelCount: Int { selectedDevice?.inputChannelCount ?? 0 }

    init() {
        selectedUID = defaults.string(forKey: Keys.selectedUID)
        if defaults.object(forKey: Keys.selectedChannels) != nil {
            selectedChannels = UInt32(defaults.integer(forKey: Keys.selectedChannels))
        }
        if defaults.object(forKey: Keys.gain) != nil {
            gain = defaults.double(forKey: Keys.gain)
        }
        engine.selectedChannels = selectedChannels
        engine.gain = gain
        launchAtLogin = LoginItem.isEnabled

        // Kicks off asynchronously; auto-start happens once the device list has actually loaded.
        wantsAutoStart = true
        refreshDevices()

        // A reconnected interface should just work again, without the app being restarted.
        enumerator.startWatching { [weak self] in
            Task { @MainActor in self?.handleDeviceListChange() }
        }

        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleMeters() }
        }

        requestMicrophoneAccess()
    }

    deinit {
        enumerator.stopWatching()
    }

    func refreshDevices() {
        let enumerator = self.enumerator
        audioQueue.async { [weak self] in
            let found = enumerator.inputDevices()
            let hasDriver = enumerator.virtualDevice() != nil
            let defaultUID = enumerator.defaultInputUID()
            Task { @MainActor in
                guard let self else { return }
                self.devices = found
                self.driverInstalled = hasDriver
                if self.selectedUID == nil || !found.contains(where: { $0.uid == self.selectedUID }) {
                    self.selectedUID = found.first(where: { $0.uid == defaultUID })?.uid ?? found.first?.uid
                }
                self.defaultChannelSelectionIfEmpty()
                self.didLoadDevices = true
                if self.wantsAutoStart, self.driverInstalled, self.selectedUID != nil {
                    self.wantsAutoStart = false
                    self.start()
                }
            }
        }
    }

    /// An empty channel selection sums nothing and produces silence. Starting up in that state means
    /// the app reports "Live" while the device is guaranteed silent, which is indistinguishable from
    /// a broken driver. Default to the first channel so there is always something to hear, and let
    /// the meters guide the choice from there.
    private func defaultChannelSelectionIfEmpty() {
        guard selectedChannels == 0, displayChannelCount > 0 else { return }
        selectedChannels = 1
    }

    /// True when the engine is running but cannot by construction produce audio.
    var isSilentByConfiguration: Bool {
        isRunning && selectedChannels == 0
    }

    func start() {
        guard let uid = selectedUID else {
            errorMessage = "No input device selected."
            return
        }
        let engine = self.engine
        audioQueue.async { [weak self] in
            var failure: String?
            do {
                try engine.start(sourceUID: uid)
            } catch {
                failure = String(describing: error)
            }
            let running = engine.isRunning
            Task { @MainActor in
                self?.errorMessage = failure
                self?.isRunning = running
            }
        }
    }

    func stop() {
        let engine = self.engine
        audioQueue.async { engine.stop() }
        isRunning = false
        outputPeak = 0
        channelPeaks = []
    }

    func toggleRunning() {
        isRunning ? stop() : start()
    }

    func isChannelSelected(_ channel: Int) -> Bool {
        channel < ChannelMixer.maxChannels && (selectedChannels & (UInt32(1) << UInt32(channel))) != 0
    }

    func setChannel(_ channel: Int, selected: Bool) {
        guard channel < ChannelMixer.maxChannels else { return }
        let bit = UInt32(1) << UInt32(channel)
        selectedChannels = selected ? (selectedChannels | bit) : (selectedChannels & ~bit)
    }

    /// The channel count that ought to be shown even when the engine is stopped, so channels can be
    /// picked before starting.
    var displayChannelCount: Int {
        min(max(channelCount, 0), ChannelMixer.maxChannels)
    }

    private func restart() {
        defaultChannelSelectionIfEmpty()
        guard isRunning else { return }
        start()
    }

    private func handleDeviceListChange() {
        let previousUID = selectedUID
        refreshDevices()
        if isRunning, selectedUID != previousUID || !engine.isRunning {
            start()
        }
    }

    private func sampleMeters() {
        guard isRunning else { return }
        let count = displayChannelCount
        channelPeaks = (0..<count).map { engine.channelPeak($0) }
        outputPeak = engine.outputPeak
        underruns = engine.status.underruns
    }


    private func requestMicrophoneAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    guard granted else {
                        self.errorMessage = "Microphone access denied. Turn MicDownmix on under System Settings > Privacy & Security > Microphone."
                        return
                    }
                    self.errorMessage = nil
                    // The engine was started before consent existed, so it is sitting stopped or
                    // silent. Nothing else will retry it, and to the user that reads as the app
                    // having ignored the permission they just granted.
                    self.start()
                }
            }
        default:
            errorMessage = "Microphone access denied. Turn MicDownmix on under System Settings > Privacy & Security > Microphone."
        }
    }
}
