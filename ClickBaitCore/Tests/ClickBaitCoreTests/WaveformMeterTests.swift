import Foundation
import Testing
@testable import ClickBaitCore

struct WaveformMeterTests {
    @Test func risesAtOnceAndFallsLikeClickys() {
        #expect(WaveformMeter.level(after: 0, rms: 0.05, dt: 1.0 / 120) == 0.51)  // 0.05 × 10.2
        #expect(WaveformMeter.level(after: 0, rms: 0.5, dt: 1.0 / 120) == 1)      // capped
        // One buffer's worth of time in silence: × 0.72.
        let oneBuffer = WaveformMeter.level(after: 1, rms: 0, dt: 1024.0 / 48_000)
        #expect(abs(oneBuffer - 0.72) < 1e-9)
        // The same fall whatever the frame rate.
        var fast = 1.0, slow = 1.0
        for _ in 0..<12 { fast = WaveformMeter.level(after: fast, rms: 0, dt: 1.0 / 120) }
        for _ in 0..<6 { slow = WaveformMeter.level(after: slow, rms: 0, dt: 1.0 / 60) }
        #expect(abs(fast - slow) < 1e-9)
    }

    @Test func barsFollowTheVoiceInClickysProfile() {
        // Silent, at the pulse's low point: 3 pt each.
        let low = -Double.pi / 2 / 3.6
        #expect(abs(WaveformMeter.barHeight(index: 0, level: 0, time: low) - 3) < 1e-9)
        // Full voice, no pulse: the middle bar is 13 pt, the outer ones 7 pt.
        #expect(abs(WaveformMeter.barHeight(index: 2, level: 1, time: 0, pulsing: false) - 13) < 1e-9)
        #expect(abs(WaveformMeter.barHeight(index: 0, level: 1, time: 0, pulsing: false) - 7) < 1e-9)
        #expect(WaveformMeter.barHeight(index: 3, level: 0.2, time: 0, pulsing: false)
                < WaveformMeter.barHeight(index: 2, level: 0.2, time: 0, pulsing: false))
    }

    @Test func idlePulseIsAtMostOneAndAHalfPoints() {
        let heights = stride(from: 0.0, to: 2, by: 0.01).map { WaveformMeter.barHeight(index: 1, level: 0, time: $0) }
        #expect((heights.max() ?? 0) <= 4.5 + 1e-9)
        #expect((heights.min() ?? 0) >= 3 - 1e-9)
    }
}
