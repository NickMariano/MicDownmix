import CoreAudio
import Foundation

/// The UID the driver publishes. Used to find the virtual device and, just as importantly, to keep
/// it out of the source device list so it cannot be fed back into itself.
public let kMicDownmixDeviceUID = "com.stealthpyro.MicDownmix.device"

/// The rates the virtual device can run at. The device is set to whatever the source interface uses,
/// so both ends agree and nothing resamples. A resampler in the path would reintroduce exactly the
/// kind of implicit conversion this app exists to avoid.
public let kMicDownmixSampleRates: [Double] = [16000, 22050, 32000, 44100, 48000, 88200, 96000]

/// Preferred when nothing else forces a choice.
public let kMicDownmixDefaultSampleRate: Double = 48000

public enum CoreAudioError: Error, CustomStringConvertible {
    case osStatus(String, OSStatus)
    case driverNotInstalled
    case sourceNotFound(String)
    case unsupportedSampleRate(actual: Double)
    case couldNotMatchSampleRate(actual: Double)

    public var description: String {
        switch self {
        case let .osStatus(what, status):
            return "\(what) failed (\(fourCC(status)))"
        case .driverNotInstalled:
            return "The audio driver is not installed yet. Open Setup to install it."
        case let .sourceNotFound(uid):
            return "Input device \"\(uid)\" is not connected."
        case let .unsupportedSampleRate(actual):
            let supported = kMicDownmixSampleRates.map { String(Int($0)) }.joined(separator: ", ")
            return "Source runs at \(Int(actual)) Hz, which is not supported. Supported rates: \(supported) Hz."
        case let .couldNotMatchSampleRate(actual):
            return "Could not set the virtual device to \(Int(actual)) Hz to match the source."
        }
    }
}

/// Renders an OSStatus as its four-character code when it is one, which most CoreAudio errors are.
public func fourCC(_ status: OSStatus) -> String {
    let value = UInt32(bitPattern: status)
    let bytes = [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
        return "'\(String(decoding: bytes, as: UTF8.self))'"
    }
    return String(status)
}

@discardableResult
func check(_ what: String, _ status: OSStatus) throws -> OSStatus {
    guard status == noErr else { throw CoreAudioError.osStatus(what, status) }
    return status
}

extension AudioObjectPropertyAddress {
    static func global(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func input(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func output(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

func propertyDataSize(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> UInt32? {
    var address = address
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return nil }
    return size
}

/// Reads a fixed-size POD property. The value is read into raw storage rather than into a `var` of
/// type `T`, because forming a raw pointer to a generic binding is only sound for trivial types and
/// the compiler cannot know that here.
func propertyValue<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, default fallback: T) -> T {
    var address = address
    var size = UInt32(MemoryLayout<T>.size)
    let storage = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { storage.deallocate() }
    storage.initialize(to: fallback)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, storage) == noErr else { return fallback }
    return storage.pointee
}

/// Reads a CFString property.
///
/// CoreAudio hands these back retained, so the result is taken as `Unmanaged` and consumed with
/// `takeRetainedValue`. Reading it as a plain `CFString?` would leak one reference per call.
func propertyString(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
    var address = address
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var value: Unmanaged<CFString>?
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
    }
    guard status == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

func propertyArray<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, of type: T.Type) -> [T] {
    guard let size = propertyDataSize(object, address), size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<T>.size
    var address = address
    var byteSize = size
    return [T](unsafeUninitializedCapacity: count) { buffer, initialized in
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &byteSize, buffer.baseAddress!)
        initialized = status == noErr ? count : 0
    }
}
