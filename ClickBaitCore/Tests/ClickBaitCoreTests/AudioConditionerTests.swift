import Testing
@testable import ClickBaitCore

struct AudioConditionerTests {
    private func tone(amplitude: Float, count: Int = 16_000) -> [Float] {
        (0..<count).map { amplitude * (($0 / 20).isMultiple(of: 2) ? 1 : -1) }
    }

    @Test func silenceIsSilent() {
        let result = AudioConditioner.condition(tone(amplitude: 0.004), sampleRate: 16_000)
        #expect(result.isSilent)
    }

    @Test func quietSpeechIsLiftedAndPadded() {
        let result = AudioConditioner.condition(tone(amplitude: 0.1), sampleRate: 16_000)
        #expect(!result.isSilent)
        #expect(abs(result.gain - 7) < 0.01)
        #expect(result.samples.count == 16_000 + 3_200)
        #expect(result.samples.prefix(3_200).allSatisfy { $0 == 0 })
        #expect(abs((result.samples.map(abs).max() ?? 0) - 0.7) < 0.001)
    }

    @Test func gainIsCappedForVeryQuietRecordings() {
        #expect(AudioConditioner.condition(tone(amplitude: 0.02), sampleRate: 16_000).gain == 12)
    }

    @Test func loudSpeechIsLeftAlone() {
        let result = AudioConditioner.condition(tone(amplitude: 0.9), sampleRate: 16_000)
        #expect(result.gain == 1)
        #expect(result.samples.suffix(16_000) == tone(amplitude: 0.9)[...])
    }
}
