import CoreAudio
import MicDownmixCore

/// A heap-backed AudioBufferList built to a chosen layout, so the mixer can be exercised against
/// exactly the buffer shapes a real interface produces without any audio hardware present.
private final class TestBufferList {
    let pointer: UnsafeMutableAudioBufferListPointer
    private var storage: [UnsafeMutablePointer<Float>] = []

    /// - Parameter channels: one entry per buffer, each entry being that buffer's channel samples in
    ///   lane order. `[[c0, c1]]` is one interleaved 2-channel buffer; `[[c0], [c1]]` is two
    ///   non-interleaved buffers.
    init(buffers: [[[Float]]]) {
        pointer = AudioBufferList.allocate(maximumBuffers: buffers.count)
        for (index, lanes) in buffers.enumerated() {
            let laneCount = lanes.count
            let frameCount = lanes.first?.count ?? 0
            let sampleCount = laneCount * frameCount
            let block = UnsafeMutablePointer<Float>.allocate(capacity: max(sampleCount, 1))
            for frame in 0..<frameCount {
                for lane in 0..<laneCount {
                    block[frame * laneCount + lane] = lanes[lane][frame]
                }
            }
            storage.append(block)
            pointer[index] = AudioBuffer(
                mNumberChannels: UInt32(laneCount),
                mDataByteSize: UInt32(sampleCount * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(block)
            )
        }
    }

    deinit {
        storage.forEach { $0.deallocate() }
        free(pointer.unsafeMutablePointer)
    }
}

private func mix(
    _ list: TestBufferList,
    mask: UInt32,
    gain: Double = 1.0,
    frames: Int,
    peaksCapacity: Int = 0
) -> (out: [Int16], peaks: [Float], summed: Int) {
    var out = [Int16](repeating: 0, count: frames)
    var accumulator = [Double](repeating: 0, count: frames)
    var peaks = [Float](repeating: 0, count: max(peaksCapacity, 1))
    var summed = 0

    out.withUnsafeMutableBufferPointer { outBuffer in
        accumulator.withUnsafeMutableBufferPointer { accBuffer in
            peaks.withUnsafeMutableBufferPointer { peakBuffer in
                summed = ChannelMixer.mixToInt16(
                    bufferList: UnsafePointer(list.pointer.unsafeMutablePointer),
                    selectedMask: mask,
                    gain: gain,
                    frameCount: frames,
                    accumulator: accBuffer.baseAddress!,
                    out: outBuffer.baseAddress!,
                    peaks: peaksCapacity > 0 ? peakBuffer.baseAddress! : nil,
                    peaksCapacity: peaksCapacity
                )
            }
        }
    }
    return (out, Array(peaks.prefix(max(peaksCapacity, 0))), summed)
}

// MARK: - Layout handling
//
// These are the cases AudioConverter mishandles. A 14-channel interface may deliver either shape,
// and picking the wrong one is precisely how the selected channel ends up silent.

private func interleavedSingleChannel() {
    scope("Interleaved: selecting one channel of many picks that channel and no other")
    // One buffer, 4 interleaved channels. Only channel 2 carries signal.
    let list = TestBufferList(buffers: [[
        [0.0, 0.0, 0.0],
        [0.0, 0.0, 0.0],
        [1.0, 0.5, -1.0],
        [0.0, 0.0, 0.0],
    ]])

    let result = mix(list, mask: 1 << 2, frames: 3)
    expect(result.summed == 1)
    expect(result.out == [32767, 16384, -32767])
}

private func nonInterleavedSingleChannel() {
    scope("Non-interleaved: selecting one channel of many picks that channel and no other")
    // Four separate single-channel buffers carrying the same signal as above.
    let list = TestBufferList(buffers: [
        [[0.0, 0.0, 0.0]],
        [[0.0, 0.0, 0.0]],
        [[1.0, 0.5, -1.0]],
        [[0.0, 0.0, 0.0]],
    ])

    let result = mix(list, mask: 1 << 2, frames: 3)
    expect(result.summed == 1)
    expect(result.out == [32767, 16384, -32767])
}

private func layoutsAgree() {
    scope("Both layouts of the same signal produce byte-identical output")
    let lanes: [[Float]] = [[0.1, -0.2, 0.3], [0.4, 0.5, -0.6], [0.0, 0.7, 0.0]]
    let interleaved = TestBufferList(buffers: [lanes])
    let planar = TestBufferList(buffers: lanes.map { [$0] })

    let mask: UInt32 = 0b101
    expect(mix(interleaved, mask: mask, frames: 3).out == mix(planar, mask: mask, frames: 3).out)
}

private func mixedLayout() {
    scope("Mixed layout: buffers carrying differing channel counts are indexed continuously")
    // Channels 0 and 1 in a stereo buffer, channel 2 alone in the next.
    let list = TestBufferList(buffers: [
        [[0.0, 0.0], [0.0, 0.0]],
        [[0.25, -0.25]],
    ])

    let result = mix(list, mask: 1 << 2, frames: 2)
    expect(result.summed == 1)
    expect(result.out == [8192, -8192])
}

// MARK: - Summing and limiting

private func summing() {
    scope("Selected channels sum, unselected ones contribute nothing")
    let list = TestBufferList(buffers: [[
        [0.25, 0.25],
        [0.25, 0.25],
        [0.90, 0.90],  // not selected; would clip the sum if it leaked in
    ]])

    let result = mix(list, mask: 0b011, frames: 2)
    expect(result.summed == 2)
    expect(result.out == [16384, 16384])  // 0.5 full scale
}

private func clipping() {
    scope("A sum beyond full scale clips rather than being rescaled")
    let list = TestBufferList(buffers: [[
        [0.8, -0.8],
        [0.8, -0.8],
    ]])

    let result = mix(list, mask: 0b011, frames: 2)
    expect(result.out == [32767, -32767])
}

private func gain() {
    scope("Gain scales the sum before limiting")
    let list = TestBufferList(buffers: [[[1.0, 0.5]]])
    expect(mix(list, mask: 0b1, gain: 0.5, frames: 2).out == [16384, 8192])
}

private func noSelection() {
    scope("No selected channels yields silence, not noise")
    let list = TestBufferList(buffers: [[[1.0, -1.0, 1.0]]])
    let result = mix(list, mask: 0, frames: 3)
    expect(result.summed == 0)
    expect(result.out == [0, 0, 0])
}

private func outOfRangeSelection() {
    scope("Selecting a channel the device does not have yields silence")
    let list = TestBufferList(buffers: [[[1.0, 1.0]]])
    let result = mix(list, mask: 1 << 13, frames: 2)
    expect(result.summed == 0)
    expect(result.out == [0, 0])
}

private func shortBuffer() {
    scope("A buffer shorter than the requested frame count is not read past its end")
    // Two frames of data, four frames requested.
    let list = TestBufferList(buffers: [[[0.5, 0.5]]])
    let result = mix(list, mask: 0b1, frames: 4)
    expect(result.out == [16384, 16384, 0, 0])
}

// MARK: - Quantization

private func quantization() {
    scope("Quantization is symmetric and rounds half away from zero")
    expect(ChannelMixer.quantize(0.0) == 0)
    expect(ChannelMixer.quantize(1.0) == 32767)
    expect(ChannelMixer.quantize(-1.0) == -32767)
    expect(ChannelMixer.quantize(2.0) == 32767)
    expect(ChannelMixer.quantize(-2.0) == -32767)
    expect(ChannelMixer.quantize(.nan) == 0)
    expect(ChannelMixer.quantize(0.5 / 32767.0) == 1)
    expect(ChannelMixer.quantize(-0.5 / 32767.0) == -1)
}

private func roundTrip() {
    scope("A quantized value survives CoreAudio's own float/int16 conversion unchanged")
    // The HAL converts our Float32 output back to Int16 using 32768. If dequantize used any other
    // scale the HAL would re-round every sample, so this asserts the grids agree.
    for value in [Int16(0), 1, -1, 32767, -32767, 12345, -12345, 255, -256] {
        let asFloat = ChannelMixer.dequantize(value)
        let backThroughCoreAudio = (Double(asFloat) * ChannelMixer.coreAudioScale).rounded()
        expect(backThroughCoreAudio == Double(value), "\(value) became \(backThroughCoreAudio)")
    }
}

// MARK: - Metering

private func peaks() {
    scope("Peaks are reported for every channel, including unselected ones")
    let list = TestBufferList(buffers: [[
        [0.1, -0.9],
        [0.5, 0.2],
        [0.0, 0.0],
    ]])

    let result = mix(list, mask: 0b1, frames: 2, peaksCapacity: 3)
    expect(result.peaks == [0.9, 0.5, 0.0])
}

let allTests: [@Sendable () -> Void] = [
    interleavedSingleChannel,
    nonInterleavedSingleChannel,
    layoutsAgree,
    mixedLayout,
    summing,
    clipping,
    gain,
    noSelection,
    outOfRangeSelection,
    shortBuffer,
    quantization,
    roundTrip,
    peaks,
]
