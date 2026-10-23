import Testing
@testable import ClickBaitCore

struct BeanTests {
    @Test func everyMoodHasDistinctPairs() {
        for mood in Bean.Mood.allCases {
            let pairs = Bean.eyePairs(for: mood)
            #expect(pairs.count >= 2)
            #expect(Set(pairs).count == pairs.count)
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

    @Test func vitalsInOrder() {
        func mood(_ cpu: Double, hot: Bool = false, battery: Double? = nil, charging: Bool = false) -> Bean.Mood? {
            Bean.mood(for: .init(cpu: cpu, hot: hot, battery: battery, charging: charging))?.mood
        }
        #expect(mood(0.2) == nil)
        #expect(mood(0.95, hot: true, battery: 0.05) == .panicked)
        #expect(mood(0.3, hot: true, battery: 0.05) == .warm)
        #expect(mood(0.3, battery: 0.05) == .sleepy)
        #expect(mood(0.3, battery: 0.15) == .tired)
        #expect(mood(0.3, battery: 0.05, charging: true) == nil)
        #expect(Bean.mood(for: .init(cpu: 0.94, hot: false, battery: nil, charging: false))?.reason == "CPU 94 %")
    }

    @Test func dockFacesNeverRepeatWhileOneIsFree() {
        var random = SystemRandomNumberGenerator()
        var worn: [Bean.EyePair] = []
        for _ in Bean.dockFaces {
            let face = Bean.dockFace(avoiding: worn, using: &random)
            #expect(!worn.contains(face))
            worn.append(face)
        }
        #expect(Bean.dockFaces.contains(Bean.dockFace(avoiding: worn, using: &random)))  // all taken: any
        #expect(Set(Bean.dockFaces).count == Bean.dockFaces.count)
    }
}
