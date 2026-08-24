import CoreAudio
import Foundation
import MicDownmixCore

// Measures every input channel of the source device at once, so the channel carrying a voice is
// identified by measurement rather than by guessing at an interface's channel map.

let seconds = CommandLine.arguments.count > 1 ? (Double(CommandLine.arguments[1]) ?? 6) : 6

let enumerator = DeviceEnumerator()
let savedUID = UserDefaults(suiteName: "com.stealthpyro.MicDownmix")?.string(forKey: "selectedSourceUID")

guard let device = savedUID.flatMap({ enumerator.device(withUID: $0) })
        ?? enumerator.inputDevices().max(by: { $0.inputChannelCount < $1.inputChannelCount }) else {
    print("No input device found.")
    exit(1)
}

let channelCount = min(device.inputChannelCount, ChannelMixer.maxChannels)
print("Source: \(device.name), \(channelCount) channels, \(Int(device.sampleRate)) Hz")
print("Listening for \(Int(seconds))s. Talk normally into the microphone now...")
print("")

final class Levels: @unchecked Sendable {
    let peak: UnsafeMutablePointer<Float>
    let sumSquares: UnsafeMutablePointer<Double>
    let count: Int
    var frames = 0
    let lock = NSLock()

    init(count: Int) {
        self.count = count
        peak = .allocate(capacity: count)
        peak.initialize(repeating: 0, count: count)
        sumSquares = .allocate(capacity: count)
        sumSquares.initialize(repeating: 0, count: count)
    }
    deinit { peak.deallocate(); sumSquares.deallocate() }
}

let levels = Levels(count: channelCount)

let ioProc: AudioDeviceIOProc = { _, _, inputData, _, _, _, clientData in
    guard let clientData else { return noErr }
    let levels = Unmanaged<Levels>.fromOpaque(clientData).takeUnretainedValue()
    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))

    levels.lock.lock()
    var channelBase = 0
    var frameTotal = 0
    for index in 0..<buffers.count {
        let buffer = buffers[index]
        let lanes = Int(buffer.mNumberChannels)
        guard lanes > 0, let raw = buffer.mData else { channelBase += lanes; continue }
        let data = raw.assumingMemoryBound(to: Float.self)
        let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * lanes)
        frameTotal = max(frameTotal, frames)
        for lane in 0..<lanes {
            let channel = channelBase + lane
            guard channel < levels.count else { continue }
            for frame in 0..<frames {
                let sample = data[frame * lanes + lane]
                let magnitude = abs(sample)
                if magnitude > levels.peak[channel] { levels.peak[channel] = magnitude }
                levels.sumSquares[channel] += Double(sample) * Double(sample)
            }
        }
        channelBase += lanes
    }
    levels.frames += frameTotal
    levels.lock.unlock()
    return noErr
}

var procID: AudioDeviceIOProcID?
guard AudioDeviceCreateIOProcID(device.id, ioProc, Unmanaged.passUnretained(levels).toOpaque(), &procID) == noErr,
      let procID, AudioDeviceStart(device.id, procID) == noErr else {
    print("Could not open \(device.name).")
    exit(1)
}
Thread.sleep(forTimeInterval: seconds)
AudioDeviceStop(device.id, procID)
AudioDeviceDestroyIOProcID(device.id, procID)

func decibels(_ value: Double) -> String {
    value > 0 ? String(format: "%6.1f dBFS", 20 * log10(value)) : "  silent"
}

struct Row { let channel: Int; let peak: Double; let rms: Double }
let frames = max(levels.frames, 1)
let rows = (0..<channelCount).map {
    Row(channel: $0, peak: Double(levels.peak[$0]), rms: (levels.sumSquares[$0] / Double(frames)).squareRoot())
}

print("Ch   peak          rms           ")
for row in rows {
    let bar = String(repeating: "#", count: Int(max(0, min(30, (20 * log10(max(row.rms, 1e-9)) + 60) / 2))))
    print(String(format: "%2d   %@  %@  %@", row.channel + 1, decibels(row.peak), decibels(row.rms), bar))
}

print("")
if let best = rows.max(by: { $0.rms < $1.rms }), best.rms > 0 {
    let others = rows.filter { $0.channel != best.channel }.map(\.rms).max() ?? 0
    let margin = others > 0 ? 20 * log10(best.rms / others) : .infinity
    print("Loudest: channel \(best.channel + 1), \(String(format: "%.1f", margin)) dB above the next.")
    if best.peak < 0.01 {
        print("But everything is near silence, so nothing was speaking. Try again while talking.")
    } else if margin < 6 {
        print("No channel stands out clearly; several may carry the same signal.")
    }
}
