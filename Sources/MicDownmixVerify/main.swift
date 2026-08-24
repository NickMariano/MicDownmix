import AudioToolbox
import CoreAudio
import Foundation
import MicDownmixCore

// A post-install check for the virtual device: confirms it exists with the format the driver is
// supposed to publish, then records from it and reports what actually arrived.
//
// Recording is the check that matters. "The device appeared" and "the device carries my voice" are
// different claims, and only the second one is the thing being built here.

let seconds = CommandLine.arguments.count > 1 ? (Double(CommandLine.arguments[1]) ?? 5) : 5
let outputPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "build/verify.wav"

let enumerator = DeviceEnumerator()

guard let device = enumerator.virtualDevice() else {
    print("FAIL  MicDownmix is not present. The driver is not installed, or coreaudiod has not")
    print("      picked it up. Open MicDownmix and use Setup to install it.")
    exit(1)
}
print("ok    device present (AudioObjectID \(device))")

// --- Format ----------------------------------------------------------------------------------

var streamsAddress = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyStreams,
    mScope: kAudioObjectPropertyScopeInput,
    mElement: kAudioObjectPropertyElementMain
)
var streamsSize: UInt32 = 0
AudioObjectGetPropertyDataSize(device, &streamsAddress, 0, nil, &streamsSize)
var streams = [AudioObjectID](repeating: 0, count: Int(streamsSize) / MemoryLayout<AudioObjectID>.size)
if !streams.isEmpty {
    AudioObjectGetPropertyData(device, &streamsAddress, 0, nil, &streamsSize, &streams)
}

guard let inputStream = streams.first else {
    print("FAIL  device has no input stream")
    exit(1)
}

func format(_ stream: AudioObjectID, _ selector: AudioObjectPropertySelector) -> AudioStreamBasicDescription? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    var value = AudioStreamBasicDescription()
    guard AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

var failures = 0
@MainActor func expect(_ condition: Bool, _ ok: String, _ bad: String) {
    if condition {
        print("ok    \(ok)")
    } else {
        print("FAIL  \(bad)")
        failures += 1
    }
}

if let physical = format(inputStream, kAudioStreamPropertyPhysicalFormat) {
    let isInt16 = (physical.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0 && physical.mBitsPerChannel == 16
    expect(isInt16,
           "physical format is 16-bit signed integer",
           "physical format is \(physical.mBitsPerChannel)-bit, flags 0x\(String(physical.mFormatFlags, radix: 16)), expected 16-bit signed integer")
    expect(physical.mChannelsPerFrame == 1,
           "device is mono",
           "device has \(physical.mChannelsPerFrame) channels, expected 1")
    expect(kMicDownmixSampleRates.contains(physical.mSampleRate),
           "sample rate is \(Int(physical.mSampleRate)) Hz",
           "sample rate is \(physical.mSampleRate) Hz, which is not one of the supported rates")
} else {
    print("FAIL  could not read the physical format")
    failures += 1
}

// --- Recording -------------------------------------------------------------------------------

print("")
print("Recording \(Int(seconds))s from MicDownmix. Speak into the source now...")

final class Capture: @unchecked Sendable {
    var samples: [Float] = []
    let lock = NSLock()
}
let capture = Capture()
capture.samples.reserveCapacity(Int(seconds * kMicDownmixDefaultSampleRate))

let ioProc: AudioDeviceIOProc = { _, _, inputData, _, _, _, clientData in
    guard let clientData else { return noErr }
    let capture = Unmanaged<Capture>.fromOpaque(clientData).takeUnretainedValue()
    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
    guard buffers.count > 0, let raw = buffers[0].mData else { return noErr }
    let lanes = max(Int(buffers[0].mNumberChannels), 1)
    let frames = Int(buffers[0].mDataByteSize) / (MemoryLayout<Float>.size * lanes)
    let data = raw.assumingMemoryBound(to: Float.self)
    capture.lock.lock()
    for frame in 0..<frames { capture.samples.append(data[frame * lanes]) }
    capture.lock.unlock()
    return noErr
}

var procID: AudioDeviceIOProcID?
guard AudioDeviceCreateIOProcID(device, ioProc, Unmanaged.passUnretained(capture).toOpaque(), &procID) == noErr,
      let procID else {
    print("FAIL  could not attach an IOProc to the device")
    exit(1)
}
guard AudioDeviceStart(device, procID) == noErr else {
    print("FAIL  could not start the device")
    exit(1)
}
Thread.sleep(forTimeInterval: seconds)
AudioDeviceStop(device, procID)
AudioDeviceDestroyIOProcID(device, procID)

capture.lock.lock()
let samples = capture.samples
capture.lock.unlock()

expect(!samples.isEmpty, "received \(samples.count) frames", "received no audio at all")

let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
let rms = samples.isEmpty ? 0 : sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count))
let decibels = peak > 0 ? 20 * log10(peak) : -.infinity

print(String(format: "      peak %.4f (%.1f dBFS), rms %.4f", peak, decibels, rms))
expect(peak > 0.001,
       "the device carried audio",
       "the device produced silence. Is the MicDownmix app running, with a channel selected?")
expect(peak < 0.999, "no clipping", "the signal is clipping; lower the gain")

// Values arriving from the device must land on the Int16 grid, since that is the whole point.
// The grid is CoreAudio's (32768), not the quantizer's clipping scale (32767); checking the latter
// reports false failures that grow with signal level.
let offGrid = samples.prefix(48000).filter { sample in
    let scaled = Double(sample) * ChannelMixer.coreAudioScale
    return abs(scaled - scaled.rounded()) > 0.01
}
expect(offGrid.isEmpty,
       "every sample lies on the 16-bit grid",
       "\(offGrid.count) samples are not 16-bit values; something is resampling or mixing downstream")

// --- WAV -------------------------------------------------------------------------------------

if !samples.isEmpty {
    let pcm = samples.map { ChannelMixer.quantize(Double($0)) }
    let dataBytes = pcm.count * 2
    var wav = Data()
    func append(_ string: String) { wav.append(contentsOf: string.utf8) }
    func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
    func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }

    append("RIFF"); append32(UInt32(36 + dataBytes)); append("WAVE")
    append("fmt "); append32(16); append16(1); append16(1)
    let rate = UInt32(format(inputStream, kAudioStreamPropertyPhysicalFormat)?.mSampleRate ?? kMicDownmixDefaultSampleRate)
    append32(rate); append32(rate * 2)
    append16(2); append16(16)
    append("data"); append32(UInt32(dataBytes))
    pcm.withUnsafeBytes { wav.append(contentsOf: $0) }

    try? FileManager.default.createDirectory(
        atPath: (outputPath as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true
    )
    try? wav.write(to: URL(fileURLWithPath: outputPath))
    print("      wrote \(outputPath)")
}

print("")
if failures == 0 {
    print("All checks passed.")
    exit(0)
}
print("\(failures) check(s) failed.")
exit(1)
