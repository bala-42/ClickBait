import Foundation
import Testing
@testable import ClickBaitCore

struct TourScoreTests {
    private let image = TourBenchmark.Image(
        name: "organs", type: "connected", path: "/nowhere.png", ignoreBelowY: 1000, neverNamed: ["VectorStock"],
        parts: [
            .init(names: ["lungs", "lung"], boxes: [[215, 345, 325, 510], [365, 345, 472, 510]], exclude: nil),
            .init(names: ["large intestine", "colon"], boxes: [[220, 615, 478, 830]], exclude: nil),
            .init(names: ["small intestine"], boxes: [[265, 670, 435, 790]], exclude: nil),
            .init(names: ["heart"], boxes: [[322, 380, 395, 485]], exclude: nil),
        ])

    @Test func namesMatchLoosely() {
        #expect(TourScore.part(named: "Colon", in: image)?.names.first == "large intestine")
        #expect(TourScore.part(named: "~ left lung", in: image)?.names.first == "lungs")
        #expect(TourScore.part(named: "Small Intestines", in: image)?.names.first == "small intestine")
        #expect(TourScore.part(named: "the heart", in: image)?.names.first == "heart")
        #expect(TourScore.part(named: "spleen", in: image) == nil)
    }

    @Test func stopsAreRightInsideAnyBoxWithSlack() {
        let stops = [
            Pointer(x: 400, y: 400, label: "Lung"),           // the right lung's box
            Pointer(x: 300, y: 700, label: "Colon"),          // inside
            Pointer(x: 600, y: 300, label: "Heart"),          // far off: wrong
            Pointer(x: 330, y: 376, label: "small intestine"),// far off: wrong
            Pointer(x: 100, y: 100, label: "Spleen"),         // not in the boxes
        ]
        let score = TourScore.score(stops: stops, named: ["Lung", "Colon", "Heart", "small intestine", "Spleen"],
                                    image: image, width: 717, height: 1080)
        #expect(score.right == ["Lung", "Colon"])
        #expect(score.wrong == ["Heart", "small intestine"])
        #expect(score.unknown == ["Spleen"])
        #expect(score.placedRight == 0.5)
        #expect(score.toured == 5)
    }

    @Test func slackIsFourPercentOfTheLongerSide() {
        // 4% of 1080 = 43.2 px outside the heart's box still counts; 50 px doesn't.
        let near = TourScore.score(stops: [Pointer(x: 395 + 43, y: 400, label: "heart")], named: ["heart"],
                                   image: image, width: 717, height: 1080)
        let far = TourScore.score(stops: [Pointer(x: 395 + 50, y: 400, label: "heart")], named: ["heart"],
                                  image: image, width: 717, height: 1080)
        #expect(near.right == ["heart"])
        #expect(far.wrong == ["heart"])
    }

    @Test func namedButNotToured() {
        let score = TourScore.score(stops: [Pointer(x: 400, y: 400, label: "heart")], named: ["heart", "colon", "lungs"],
                                    image: image, width: 717, height: 1080)
        #expect(score.dropped == ["large intestine", "lungs"])
    }

    @Test func excludedAreasDontCount() {
        let brain = TourBenchmark.Image(name: "brain", type: "connected", path: "/b.png", ignoreBelowY: nil, neverNamed: nil,
                                        parts: [.init(names: ["cerebrum"], boxes: [[30, 30, 1275, 820]], exclude: [[300, 385, 1120, 1000]])])
        let score = TourScore.score(stops: [Pointer(x: 200, y: 200, label: "cerebrum"), Pointer(x: 600, y: 500, label: "cerebrum")],
                                    named: ["cerebrum"], image: brain, width: 1300, height: 1059)
        #expect(score.right == ["cerebrum"])
        #expect(score.wrong == ["cerebrum"])
    }

    @Test func theBoxesFileLoads() throws {
        let json = #"{"images":[{"name":"x","type":"t","path":"/p.png","parts":[{"names":["a"],"boxes":[[1,2,3,4]]}]}]}"#
        let url = FileManager.default.temporaryDirectory.appending(path: "boxes-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let benchmark = try TourBenchmark.load(from: url)
        #expect(benchmark.images.first?.parts.first?.boxes == [[1, 2, 3, 4]])
    }
}
