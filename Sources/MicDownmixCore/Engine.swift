import CoreAudio
import Foundation
import Synchronization

/// State shared between the two IO callbacks and the UI.
///
/// Everything the realtime threads touch lives here in preallocated storage or atomics. No Swift
/// collection, string, or allocation is reachable from either callback.
final class EngineContext: @unchecked Sendable {

    // Bridge ring between the source callback (producer) and the virtual device callback (consumer).
    // Capacity is a power of two so wrapping is a mask rather than a division.
    let ring: UnsafeMutablePointer<Int16>
    let ringCapacity: Int
    let ringMask: Int
    let writeIndex = Atomic<Int>(0)
    let readIndex = Atomic<Int>(0)

    // Scratch for the mixer, sized to the largest IO buffer either device will ask for.
    let accumulator: UnsafeMutablePointer<Double>
    let mixed: UnsafeMutablePointer<Int16>
    let peaks: UnsafeMutablePointer<Float>
    let maxFrames: Int
    let peaksCapacity: Int

    // Live controls, written by the UI and read by the callbacks.
    let selectedMask = Atomic<UInt32>(0)
    let gainBits: Atomic<UInt64>

    // Telemetry, read by the UI.
    let outputPeakBits = Atomic<UInt32>(0)
    let underruns = Atomic<Int>(0)
    let overruns = Atomic<Int>(0)
    let driftCorrections = Atomic<Int>(0)

    /// Frames the consumer waits for before it starts draining. Without this the two independent
    /// clocks would leave the ring hovering at empty and underrun on every cycle.
    let primeFrames: Int
    let isPrimed = Atomic<Bool>(false)

    init(maxFrames: Int, peaksCapacity: Int, ringCapacity: Int, primeFrames: Int) {
        self.maxFrames = maxFrames
        self.peaksCapacity = peaksCapacity
        self.ringCapacity = ringCapacity
        self.ringMask = ringCapacity - 1
        self.primeFrames = primeFrames
        ring = .allocate(capacity: ringCapacity)
        ring.initialize(repeating: 0, count: ringCapacity)
        accumulator = .allocate(capacity: maxFrames)
        accumulator.initialize(repeating: 0, count: maxFrames)
        mixed = .allocate(capacity: maxFrames)
        mixed.initialize(repeating: 0, count: maxFrames)
        peaks = .allocate(capacity: peaksCapacity)
        peaks.initialize(repeating: 0, count: peaksCapacity)
        gainBits = Atomic<UInt64>(1.0.bitPattern)
    }

    deinit {
        ring.deallocate()
        accumulator.deallocate()
        mixed.deallocate()
        peaks.deallocate()
    }

    var gain: Double {
        get { Double(bitPattern: gainBits.load(ordering: .relaxed)) }
        set { gainBits.store(newValue.bitPattern, ordering: .relaxed) }
    }

    var outputPeak: Float {
        get { Float(bitPattern: outputPeakBits.load(ordering: .relaxed)) }
        set { outputPeakBits.store(newValue.bitPattern, ordering: .relaxed) }
    }

    var fillLevel: Int {
        writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .relaxed)
    }

    func channelPeak(_ channel: Int) -> Float {
        channel < peaksCapacity ? peaks[channel] : 0
    }

    func reset() {
        writeIndex.store(0, ordering: .relaxed)
        readIndex.store(0, ordering: .relaxed)
        isPrimed.store(false, ordering: .relaxed)
        underruns.store(0, ordering: .relaxed)
        overruns.store(0, ordering: .relaxed)
        driftCorrections.store(0, ordering: .relaxed)
        outputPeak = 0
        ring.update(repeating: 0, count: ringCapacity)
        peaks.update(repeating: 0, count: peaksCapacity)
    }
}

// MARK: - Realtime callbacks
//
// Both are C function pointers taking the context by unretained opaque pointer, so no reference
// counting happens on the audio threads.

private let sourceIOProc: AudioDeviceIOProc = { _, _, inputData, _, _, _, clientData in
    guard let clientData else { return noErr }
    let context = Unmanaged<EngineContext>.fromOpaque(clientData).takeUnretainedValue()

    // Frame count comes from the first buffer; every buffer in a list carries the same frame count.
    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
    guard buffers.count > 0 else { return noErr }
    let firstLanes = max(Int(buffers[0].mNumberChannels), 1)
    let frames = min(Int(buffers[0].mDataByteSize) / (MemoryLayout<Float>.size * firstLanes), context.maxFrames)
    guard frames > 0 else { return noErr }

    ChannelMixer.mixToInt16(
        bufferList: UnsafePointer(inputData),
        selectedMask: context.selectedMask.load(ordering: .relaxed),
        gain: context.gain,
        frameCount: frames,
        accumulator: context.accumulator,
        out: context.mixed,
        peaks: context.peaks,
        peaksCapacity: context.peaksCapacity
    )

    var peak: Float = 0
    for frame in 0..<frames {
        let magnitude = abs(ChannelMixer.dequantize(context.mixed[frame]))
        if magnitude > peak { peak = magnitude }
    }
    context.outputPeak = peak

    // Push into the bridge. If the consumer has fallen far enough behind that the ring is full, drop
    // the oldest audio rather than the newest: on a live microphone the most recent audio is the
    // audio that matters.
    let writeIndex = context.writeIndex.load(ordering: .relaxed)
    let readIndex = context.readIndex.load(ordering: .acquiring)
    let free = context.ringCapacity - (writeIndex - readIndex)
    if free < frames {
        context.readIndex.store(readIndex + (frames - free), ordering: .releasing)
        context.overruns.wrappingAdd(1, ordering: .relaxed)
    }
    for frame in 0..<frames {
        context.ring[(writeIndex + frame) & context.ringMask] = context.mixed[frame]
    }
    context.writeIndex.store(writeIndex + frames, ordering: .releasing)

    return noErr
}

private let virtualIOProc: AudioDeviceIOProc = { _, _, _, _, outputData, _, clientData in
    guard let clientData else { return noErr }
    let context = Unmanaged<EngineContext>.fromOpaque(clientData).takeUnretainedValue()

    let buffers = UnsafeMutableAudioBufferListPointer(outputData)
    guard buffers.count > 0, let rawOut = buffers[0].mData else { return noErr }
    let lanes = max(Int(buffers[0].mNumberChannels), 1)
    let frames = Int(buffers[0].mDataByteSize) / (MemoryLayout<Float>.size * lanes)
    guard frames > 0 else { return noErr }
    let out = rawOut.assumingMemoryBound(to: Float.self)

    var readIndex = context.readIndex.load(ordering: .relaxed)
    let writeIndex = context.writeIndex.load(ordering: .acquiring)
    var available = writeIndex - readIndex

    // Wait for the ring to build up before draining it. The source device and the virtual device run
    // off independent clocks, so starting to consume at the first available frame guarantees a
    // starved ring and a stutter on every cycle.
    if !context.isPrimed.load(ordering: .relaxed) {
        if available < context.primeFrames {
            for index in 0..<(frames * lanes) { out[index] = 0 }
            return noErr
        }
        context.isPrimed.store(true, ordering: .relaxed)
    }

    // Independent clocks also drift. Rather than resample, absorb the drift by dropping or repeating
    // a single frame once the fill level strays outside a generous band. At the rate two nominal
    // 48 kHz clocks diverge this happens seconds apart and is inaudible.
    let target = context.primeFrames
    if available > target * 2 {
        readIndex += 1
        available -= 1
        context.driftCorrections.wrappingAdd(1, ordering: .relaxed)
    }

    for frame in 0..<frames {
        var sample: Float = 0
        if frame < available {
            sample = ChannelMixer.dequantize(context.ring[(readIndex + frame) & context.ringMask])
        } else if frame == 0 {
            context.underruns.wrappingAdd(1, ordering: .relaxed)
            context.isPrimed.store(false, ordering: .relaxed)
        }
        // Mono device, but write every lane so a host that opens it wider still hears something.
        for lane in 0..<lanes {
            out[frame * lanes + lane] = sample
        }
    }

    context.readIndex.store(readIndex + min(frames, available), ordering: .releasing)
    return noErr
}

// MARK: - Engine

/// Reads a hardware input, collapses the selected channels to mono Int16 by hand, and feeds the
/// result to the virtual device so anything on the machine can select it as a microphone.
public final class AudioEngine: @unchecked Sendable {

    public struct Status: Sendable {
        public var isRunning = false
        public var sourceName: String?
        public var sourceChannelCount = 0
        public var underruns = 0
        public var overruns = 0
        public var driftCorrections = 0
    }

    /// Largest IO buffer either device is expected to request. CoreAudio will not exceed this in
    /// practice; the mixer additionally clamps to it, so an overlarge request degrades to a short
    /// buffer rather than a memory error.
    private static let maxFrames = 4096
    private static let ringCapacity = 16384
    private static let primeFrames = 1024
    private static let maxSourceChannels = ChannelMixer.maxChannels

    private let context = EngineContext(
        maxFrames: maxFrames,
        peaksCapacity: maxSourceChannels,
        ringCapacity: ringCapacity,
        primeFrames: primeFrames
    )

    private var sourceDeviceID: AudioObjectID?
    private var sourceProcID: AudioDeviceIOProcID?
    private var virtualDeviceID: AudioObjectID?
    private var virtualProcID: AudioDeviceIOProcID?

    private(set) public var sourceChannelCount = 0
    private(set) public var sourceName: String?
    public var isRunning: Bool { sourceProcID != nil && virtualProcID != nil }

    public init() {}

    public var selectedChannels: UInt32 {
        get { context.selectedMask.load(ordering: .relaxed) }
        set { context.selectedMask.store(newValue, ordering: .relaxed) }
    }

    public var gain: Double {
        get { context.gain }
        set { context.gain = newValue }
    }

    public func channelPeak(_ channel: Int) -> Float { context.channelPeak(channel) }
    public var outputPeak: Float { context.outputPeak }

    public var status: Status {
        Status(
            isRunning: isRunning,
            sourceName: sourceName,
            sourceChannelCount: sourceChannelCount,
            underruns: context.underruns.load(ordering: .relaxed),
            overruns: context.overruns.load(ordering: .relaxed),
            driftCorrections: context.driftCorrections.load(ordering: .relaxed)
        )
    }

    /// Starts feeding the virtual device from `sourceUID`.
    ///
    /// Throws rather than silently degrading when the source is missing, the driver is not installed,
    /// or the source is not at 48 kHz. Each of those would otherwise show up as an unexplained
    /// silent microphone.
    public func start(sourceUID: String) throws {
        stop()

        let enumerator = DeviceEnumerator()
        guard let source = enumerator.device(withUID: sourceUID) else {
            throw CoreAudioError.sourceNotFound(sourceUID)
        }
        guard source.supportsRequiredSampleRate else {
            throw CoreAudioError.unsupportedSampleRate(actual: source.sampleRate)
        }
        guard let virtual = enumerator.virtualDevice() else {
            throw CoreAudioError.driverNotInstalled
        }

        // Match the virtual device to the source rather than demanding the source change. Both ends
        // then run at the same rate and no resampling is needed anywhere.
        try Self.setSampleRate(source.sampleRate, on: virtual)

        sourceName = source.name
        sourceChannelCount = min(source.inputChannelCount, Self.maxSourceChannels)
        context.reset()

        let clientData = Unmanaged.passUnretained(context).toOpaque()

        var sourceProc: AudioDeviceIOProcID?
        try check("AudioDeviceCreateIOProcID(source)",
                  AudioDeviceCreateIOProcID(source.id, sourceIOProc, clientData, &sourceProc))
        sourceDeviceID = source.id
        sourceProcID = sourceProc

        var virtualProc: AudioDeviceIOProcID?
        try check("AudioDeviceCreateIOProcID(virtual)",
                  AudioDeviceCreateIOProcID(virtual, virtualIOProc, clientData, &virtualProc))
        virtualDeviceID = virtual
        virtualProcID = virtualProc

        // Start the consumer first so it is already priming when audio begins to arrive.
        try check("AudioDeviceStart(virtual)", AudioDeviceStart(virtual, virtualProc))
        do {
            try check("AudioDeviceStart(source)", AudioDeviceStart(source.id, sourceProc))
        } catch {
            stop()
            throw error
        }
    }

    /// Sets a device's nominal sample rate and waits for it to take effect.
    ///
    /// The change is asynchronous: the HAL stops IO, asks the driver to apply it, and restarts.
    /// Returning before it has settled would have the IOProc running at the old rate.
    static func setSampleRate(_ rate: Double, on device: AudioObjectID) throws {
        var address = AudioObjectPropertyAddress.global(kAudioDevicePropertyNominalSampleRate)
        let current = propertyValue(device, .global(kAudioDevicePropertyNominalSampleRate), default: 0.0)
        if current == rate { return }

        var value = rate
        let status = AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &value
        )
        guard status == noErr else { throw CoreAudioError.osStatus("set virtual device rate", status) }

        // Poll briefly rather than assume. Two seconds is far longer than the HAL needs.
        for _ in 0..<40 {
            if propertyValue(device, .global(kAudioDevicePropertyNominalSampleRate), default: 0.0) == rate {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw CoreAudioError.couldNotMatchSampleRate(actual: rate)
    }

    public func stop() {
        if let id = sourceDeviceID, let proc = sourceProcID {
            AudioDeviceStop(id, proc)
            AudioDeviceDestroyIOProcID(id, proc)
        }
        if let id = virtualDeviceID, let proc = virtualProcID {
            AudioDeviceStop(id, proc)
            AudioDeviceDestroyIOProcID(id, proc)
        }
        sourceDeviceID = nil
        sourceProcID = nil
        virtualDeviceID = nil
        virtualProcID = nil
        sourceName = nil
        sourceChannelCount = 0
    }

    deinit { stop() }
}
