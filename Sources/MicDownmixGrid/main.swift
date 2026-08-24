import CoreAudio
import Foundation
import MicDownmixCore

// Which integer grid do the samples coming back off the virtual device actually land on?
// CoreAudio's own float/int16 conversion uses 32768; this project quantizes with 32767. If those
// disagree, values are being requantized in flight.

let enumerator = DeviceEnumerator()
guard let device = enumerator.virtualDevice() else { exit(1) }

final class Cap: @unchecked Sendable { var s: [Float] = []; let l = NSLock() }
let cap = Cap()

let proc: AudioDeviceIOProc = { _, _, input, _, _, _, cd in
    guard let cd else { return noErr }
    let cap = Unmanaged<Cap>.fromOpaque(cd).takeUnretainedValue()
    let b = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    guard b.count > 0, let raw = b[0].mData else { return noErr }
    let lanes = max(Int(b[0].mNumberChannels), 1)
    let frames = Int(b[0].mDataByteSize) / (MemoryLayout<Float>.size * lanes)
    let d = raw.assumingMemoryBound(to: Float.self)
    cap.l.lock(); for f in 0..<frames { cap.s.append(d[f * lanes]) }; cap.l.unlock()
    return noErr
}

var id: AudioDeviceIOProcID?
AudioDeviceCreateIOProcID(device, proc, Unmanaged.passUnretained(cap).toOpaque(), &id)
AudioDeviceStart(device, id!)
Thread.sleep(forTimeInterval: 3)
AudioDeviceStop(device, id!); AudioDeviceDestroyIOProcID(device, id!)

cap.l.lock(); let s = cap.s.filter { $0 != 0 }; cap.l.unlock()
guard !s.isEmpty else { print("no non-zero samples"); exit(1) }

func offGrid(_ scale: Double) -> (count: Int, worst: Double) {
    var worst = 0.0, count = 0
    for v in s {
        let scaled = Double(v) * scale
        let err = abs(scaled - scaled.rounded())
        if err > worst { worst = err }
        if err > 0.01 { count += 1 }
    }
    return (count, worst)
}

let a = offGrid(32767), b = offGrid(32768)
print("samples examined: \(s.count)")
print(String(format: "against 32767 grid: %d off, worst error %.4f", a.count, a.worst))
print(String(format: "against 32768 grid: %d off, worst error %.4f", b.count, b.worst))
print("")
print(a.worst < b.worst ? "-> data is on the 32767 grid" : "-> data is on the 32768 grid (CoreAudio's own scale)")
