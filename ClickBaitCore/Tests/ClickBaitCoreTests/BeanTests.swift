import Testing
@testable import ClickBaitCore

struct BeanTests {
    @Test func everyMoodHasTwoEyes() {
        for mood in Bean.Mood.allCases {
            let pairs = Bean.eyePairs(for: mood)
            #expect(pairs.count >= 2)
            for pair in pairs { #expect(pair.split(separator: " ").count == 2) }
        }
    }

    @Test func newEyesEachTime() {
        var random = SystemRandomNumberGenerator()
        for mood in Bean.Mood.allCases {
            for previous in Bean.eyePairs(for: mood) {
                let eyes = Bean.eyes(for: mood, avoiding: previous, using: &random)
                #expect(eyes != previous)
                #expect(Bean.eyePairs(for: mood).contains(eyes))
            }
        }
    }

    @Test func mouthFollowsMood() {
        #expect(Bean.mouth(for: .happy) == .grin)
        #expect(Bean.mouth(for: .error) == .frown)
        #expect(Bean.mouth(for: .listening) == .open)
    }
}
