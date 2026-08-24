import CoreAudio

/// Collapses a multi-channel Float32 buffer to a single Int16 channel.
///
/// This exists because `AudioConverter` cannot be trusted to downmix multi-channel Float32 to mono
/// Int16: it infers a channel map from the stream description and gets that inference wrong for
/// interfaces presenting many channels, yielding silence or garbage rather than the selected input.
///
/// Everything here is explicit. No channel map is inferred and no CoreAudio conversion component is
/// involved at any point.
public enum ChannelMixer {

    /// Full-scale Int16. 32767 rather than 32768 keeps the mapping symmetric, so -1.0 and +1.0
    /// quantize to -32767 and +32767 and neither end can wrap.
    public static let fullScale: Double = 32767.0

    /// The largest source channel index that can be selected, bounded by the width of the mask.
    public static let maxChannels = 32

    /// Sums the selected channels of `bufferList` into `out` as Int16.
    ///
    /// Handles every layout CoreAudio can hand an input IOProc, by walking the buffer list rather
    /// than assuming a shape:
    ///   - interleaved:     one buffer, `mNumberChannels == N`, samples strided by N
    ///   - non-interleaved: N buffers, `mNumberChannels == 1`, samples contiguous
    ///   - mixed:           several buffers each carrying some channels
    ///
    /// - Parameters:
    ///   - bufferList: input, Float32, as delivered by a device IOProc in its virtual format.
    ///   - selectedMask: bit *i* selects source channel *i*, counted across buffers in order.
    ///   - gain: linear gain applied to the sum before limiting.
    ///   - frameCount: frames to produce.
    ///   - accumulator: caller-owned scratch, capacity at least `frameCount`. Supplied by the caller
    ///     so this routine can run on a realtime thread without allocating.
    ///   - out: destination, capacity at least `frameCount`.
    ///   - peaks: optional, receives the absolute peak of *every* channel, selected or not, so the UI
    ///     can show which channel actually carries signal.
    ///   - peaksCapacity: how many entries `peaks` can hold.
    /// - Returns: the number of channels summed.
    ///
    /// Realtime safe: no allocation, no locking, no reference counting.
    @discardableResult
    public static func mixToInt16(
        bufferList: UnsafePointer<AudioBufferList>,
        selectedMask: UInt32,
        gain: Double,
        frameCount: Int,
        accumulator: UnsafeMutablePointer<Double>,
        out: UnsafeMutablePointer<Int16>,
        peaks: UnsafeMutablePointer<Float>? = nil,
        peaksCapacity: Int = 0
    ) -> Int {
        guard frameCount > 0 else { return 0 }

        // Start from silence, so a frame that no buffer supplies stays silent rather than retaining
        // whatever the destination happened to hold.
        accumulator.update(repeating: 0, count: frameCount)
        if let peaks {
            peaks.update(repeating: 0, count: peaksCapacity)
        }

        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        var summedChannels = 0
        var channelBase = 0

        for bufferIndex in 0..<buffers.count {
            let buffer = buffers[bufferIndex]
            let lanes = Int(buffer.mNumberChannels)
            guard lanes > 0 else { continue }

            guard let rawData = buffer.mData else {
                channelBase += lanes
                continue
            }
            let data = rawData.assumingMemoryBound(to: Float.self)

            // Trust the byte count over the requested frame count. A short buffer must not be read
            // past its end just because the IOProc asked for more frames.
            let framesAvailable = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * lanes)
            let frames = min(frameCount, framesAvailable)

            for lane in 0..<lanes {
                let channel = channelBase + lane
                let wantPeak = peaks != nil && channel < peaksCapacity
                let selected = channel < maxChannels
                    && (selectedMask & (UInt32(1) << UInt32(channel))) != 0

                if !selected && !wantPeak { continue }

                var peak: Float = 0
                var index = lane
                for frame in 0..<frames {
                    let sample = data[index]
                    index += lanes
                    if selected {
                        // Accumulate in Double: summing many channels overruns Float32's precision
                        // exactly where the limiting decision has to be made.
                        accumulator[frame] += Double(sample)
                    }
                    if wantPeak {
                        let magnitude = sample < 0 ? -sample : sample
                        if magnitude > peak { peak = magnitude }
                    }
                }

                if wantPeak { peaks![channel] = peak }
                if selected { summedChannels += 1 }
            }

            channelBase += lanes
        }

        for frame in 0..<frameCount {
            out[frame] = quantize(accumulator[frame] * gain)
        }

        return summedChannels
    }

    /// Hard limits to [-1, 1] and quantizes to Int16, rounding half away from zero.
    ///
    /// Clipping rather than normalizing is deliberate. A limiter that silently rescaled would make a
    /// too-hot input sound quiet instead of distorted, hiding the problem from whoever is setting
    /// their gain.
    @inline(__always)
    public static func quantize(_ value: Double) -> Int16 {
        if value.isNaN { return 0 }
        let limited = value < -1.0 ? -1.0 : (value > 1.0 ? 1.0 : value)
        return Int16((limited * fullScale).rounded(.toNearestOrAwayFromZero))
    }

    /// The scale CoreAudio itself uses when converting between Float32 and 16-bit integer samples.
    ///
    /// It is deliberately not `fullScale`. Quantizing with 32767 keeps clipping symmetric, but the
    /// HAL converts our Float32 output back to Int16 using 32768. Dividing by 32767 on the way out
    /// would hand the HAL values that do not sit on its grid, and it would re-round them: every
    /// sample could shift by one LSB after all the care taken to compute it exactly.
    ///
    /// Measured, not assumed. `MicDownmixGrid` reads the live device and reports which grid the
    /// samples land on; against 32768 the worst observed error is 0.0000.
    public static let coreAudioScale: Double = 32768.0

    /// The inverse, used to hand the driver exactly the values that were quantized, so what arrives
    /// downstream is the Int16 signal and not a re-rounded approximation of it.
    @inline(__always)
    public static func dequantize(_ value: Int16) -> Float {
        Float(value) / Float(coreAudioScale)
    }
}
