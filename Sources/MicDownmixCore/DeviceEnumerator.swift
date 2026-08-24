import CoreAudio
import Foundation

public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let inputChannelCount: Int
    public let sampleRate: Double

    public var supportsRequiredSampleRate: Bool { kMicDownmixSampleRates.contains(sampleRate) }
}

/// Lists the hardware inputs that can feed the virtual mic, and watches for the list changing.
public final class DeviceEnumerator: @unchecked Sendable {

    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var onChange: (@Sendable () -> Void)?

    public init() {}

    /// Every device with at least one input channel, excluding our own virtual device.
    ///
    /// The exclusion is not cosmetic: selecting the virtual device as its own source would loop its
    /// output back into its input.
    public func inputDevices() -> [AudioInputDevice] {
        propertyArray(AudioObjectID(kAudioObjectSystemObject), .global(kAudioHardwarePropertyDevices), of: AudioObjectID.self)
            .compactMap(describe)
            .filter { $0.inputChannelCount > 0 && $0.uid != kMicDownmixDeviceUID }
    }

    /// The virtual device the driver publishes, or nil when the driver is not installed.
    public func virtualDevice() -> AudioObjectID? {
        propertyArray(AudioObjectID(kAudioObjectSystemObject), .global(kAudioHardwarePropertyDevices), of: AudioObjectID.self)
            .first { propertyString($0, .global(kAudioDevicePropertyDeviceUID)) == kMicDownmixDeviceUID }
    }

    /// The system default input, so a first run has a sensible selection.
    public func defaultInputUID() -> String? {
        let id = propertyValue(
            AudioObjectID(kAudioObjectSystemObject),
            .global(kAudioHardwarePropertyDefaultInputDevice),
            default: AudioObjectID(kAudioObjectUnknown)
        )
        guard id != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return propertyString(id, .global(kAudioDevicePropertyDeviceUID))
    }

    public func device(withUID uid: String) -> AudioInputDevice? {
        inputDevices().first { $0.uid == uid }
    }

    private func describe(_ id: AudioObjectID) -> AudioInputDevice? {
        guard let uid = propertyString(id, .global(kAudioDevicePropertyDeviceUID)) else { return nil }
        let name = propertyString(id, .global(kAudioObjectPropertyName)) ?? uid
        return AudioInputDevice(
            id: id,
            uid: uid,
            name: name,
            inputChannelCount: Self.inputChannelCount(of: id),
            sampleRate: propertyValue(id, .global(kAudioDevicePropertyNominalSampleRate), default: 0.0)
        )
    }

    /// Total input channels, summed across the device's input buffers.
    ///
    /// Summing across buffers rather than reading the first one is what makes this correct for both
    /// interleaved and non-interleaved devices, the same distinction the mixer handles.
    public static func inputChannelCount(of id: AudioObjectID) -> Int {
        let address = AudioObjectPropertyAddress.input(kAudioDevicePropertyStreamConfiguration)
        guard let size = propertyDataSize(id, address), size > 0 else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }

        var mutableAddress = address
        var byteSize = size
        guard AudioObjectGetPropertyData(id, &mutableAddress, 0, nil, &byteSize, raw) == noErr else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return (0..<list.count).reduce(0) { $0 + Int(list[$1].mNumberChannels) }
    }

    /// Calls `handler` whenever devices are added or removed, so a reconnected interface is picked
    /// back up without the app being restarted.
    public func startWatching(_ handler: @escaping @Sendable () -> Void) {
        stopWatching()
        onChange = handler
        var address = AudioObjectPropertyAddress.global(kAudioHardwarePropertyDevices)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
    }

    public func stopWatching() {
        guard let block = listenerBlock else { return }
        var address = AudioObjectPropertyAddress.global(kAudioHardwarePropertyDevices)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        listenerBlock = nil
        onChange = nil
    }

    deinit { stopWatching() }
}
