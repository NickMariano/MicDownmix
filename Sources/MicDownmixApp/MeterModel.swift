import Foundation
import MicDownmixCore
import SwiftUI

/// Live level meters, deliberately kept off `AppState`.
///
/// SwiftUI re-evaluates a view whenever any observed object publishes, and the menu bar label
/// observes `AppState`. With meters living there, every one of the thirty updates a second
/// invalidated the label, and AppKit answered each invalidation by re-rendering the status item and
/// snapshotting its layer. That cost around 40% of a CPU, permanently, to animate meters that were
/// usually not even on screen.
///
/// Separating them means meter updates reach only the panel that draws them, and the menu bar icon
/// is redrawn only when the thing it actually depicts changes.
@MainActor
final class MeterModel: ObservableObject {

    @Published private(set) var channelPeaks: [Float] = []
    @Published private(set) var outputPeak: Float = 0

    private var timer: Timer?
    private var subscribers = 0
    private weak var engine: AudioEngine?
    private var channelCount: () -> Int = { 0 }

    func configure(engine: AudioEngine, channelCount: @escaping () -> Int) {
        self.engine = engine
        self.channelCount = channelCount
    }

    /// Starts sampling. Balanced by `end()`, so several views can ask independently.
    func begin() {
        subscribers += 1
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    func end() {
        subscribers = max(0, subscribers - 1)
        guard subscribers == 0 else { return }
        timer?.invalidate()
        timer = nil
        channelPeaks = []
        outputPeak = 0
    }

    private func sample() {
        guard let engine, engine.isRunning else { return }
        let peaks = (0..<channelCount()).map { engine.channelPeak($0) }
        let output = engine.outputPeak

        // Publishing an identical value still costs an invalidation and a layout pass, so only
        // publish movement a meter could actually show.
        if peaks.count != channelPeaks.count
            || zip(peaks, channelPeaks).contains(where: { abs($0 - $1) > 0.002 }) {
            channelPeaks = peaks
        }
        if abs(output - outputPeak) > 0.002 { outputPeak = output }
    }
}
