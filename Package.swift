// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MicDownmix",
    platforms: [.macOS(.v15)],
    targets: [
        // The signal path. Deliberately free of any UI or app lifecycle dependency so that the
        // mixing and quantization can be tested without audio hardware.
        .target(name: "MicDownmixCore"),
        .executableTarget(name: "MicDownmixApp", dependencies: ["MicDownmixCore"]),
        // Tests run as a plain executable: no XCTest or swift-testing in Command Line Tools.
        .executableTarget(name: "MicDownmixTests", dependencies: ["MicDownmixCore"]),
        // Post-install end-to-end check against the real virtual device.
        .executableTarget(name: "MicDownmixVerify", dependencies: ["MicDownmixCore"]),
        // Measures every source channel, to find which one carries the voice.
        .executableTarget(name: "MicDownmixProbe", dependencies: ["MicDownmixCore"]),
        .executableTarget(name: "MicDownmixGrid", dependencies: ["MicDownmixCore"]),
    ]
)
