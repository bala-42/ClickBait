import Foundation
import Testing
@testable import ClickBaitCore

struct PartsTourTests {
    private let marked = Rect(x: 100, y: 100, width: 600, height: 400)

    @Test func parsesPartsAndListsThemInTheChat() {
        let raw = #"{"speech": "The rotator cuff, four muscles that hold the shoulder.", "parts": [{"x": 300, "y": 200, "label": "Supraspinatus"}, {"x": 450, "y": 320, "label": "Infraspinatus"}]}"#
        let response = ResponseParser.parse(raw, imageWidth: 800, imageHeight: 600).response
        #expect(response.parts.map(\.label) == ["Supraspinatus", "Infraspinatus"])
        #expect(response.displayText == "The rotator cuff, four muscles that hold the shoulder.")  // pointed at, not listed
    }

    @Test func stopsAreThePartsInsideTheMarkedArea() {
        let parts = [Pointer(x: 200, y: 150, label: "Subscapularis"), Pointer(x: 400, y: 200, label: "Supraspinatus"),
                     Pointer(x: 900, y: 150, label: "Far away"), Pointer(x: 410, y: 205, label: "supraspinatus")]
        #expect(PartsTour.stops(parts, marked: marked).map(\.label) == ["Subscapularis", "Supraspinatus"])
    }

    @Test func evenOnePartIsPointedAt() {
        #expect(PartsTour.stops([Pointer(x: 300, y: 300, label: "Liver")], marked: marked).count == 1)
        let many = (0..<12).map { Pointer(x: 150 + Double($0) * 30, y: 300, label: "Part \($0)") }  // more than the cap
        #expect(PartsTour.stops(many, marked: marked).count == PartsTour.maxParts)
    }
}

struct PartsMatcherTests {
    // Printed labels of the rotator cuff test diagram (at 1280 wide).
    private let text = [
        TextBox(text: "Rotator cuff (posterior and anterior view)", center: Point(x: 640, y: 50)),
        TextBox(text: "Supraspinatus", center: Point(x: 540, y: 205)),
        TextBox(text: "Infraspinatus", center: Point(x: 920, y: 432)),
        TextBox(text: "Teres minor", center: Point(x: 840, y: 672)),
        TextBox(text: "Subscapularis", center: Point(x: 250, y: 474)),
    ]

    @Test func swappedNamesAreFixedByPrintedLabels() {
        // Real qwen2.5vl:7b reply: right shapes, wrong names.
        let parts = [Pointer(x: 640, y: 194, label: "Supraspinatus"), Pointer(x: 320, y: 473, label: "Infraspinatus"),
                     Pointer(x: 970, y: 430, label: "Teres minor"), Pointer(x: 850, y: 650, label: "Subscapularis")]
        let result = PartsMatcher.match(parts: parts, speech: "", text: text)
        #expect(result.verified == [
            Pointer(x: 540, y: 205, label: "Supraspinatus"), Pointer(x: 920, y: 432, label: "Infraspinatus"),
            Pointer(x: 840, y: 672, label: "Teres minor"), Pointer(x: 250, y: 474, label: "Subscapularis"),
        ])
        #expect(result.unverified.isEmpty)
    }

    @Test func namesInTheExplanationBecomePartsToo() {
        // Real reply that listed no parts, only named them.
        let speech = "The rotator cuff is a group of four muscles: the supraspinatus, infraspinatus, teres minor, and subscapularis."
        let result = PartsMatcher.match(parts: [], speech: speech, text: text)
        #expect(result.verified.map(\.label) == ["Supraspinatus", "Infraspinatus", "Teres minor", "Subscapularis"])
    }

    @Test func unprintedNamesStayUnverified() {
        let parts = [Pointer(x: 640, y: 450, label: "Humeral head"), Pointer(x: 640, y: 194, label: "Supraspinatus")]
        let result = PartsMatcher.match(parts: parts, speech: "", text: text)
        #expect(result.verified.map(\.label) == ["Supraspinatus"])
        #expect(result.unverified.map(\.label) == ["Humeral head"])
    }
}

struct CoordinateScrubberTests {
    @Test func pullsAPartsListOutOfTheText() {
        // Real qwen2.5vl:7b reply text (the visual pathway image).
        let text = #"This image shows a cross-section of the brain, highlighting the optic chiasm and optic nerves. The optic nerves carry visual information. Parts: {"x": 400, "y": 200, "label": "Optic Chiasm"}, {"x": 300, "y": 500, "label": "Optic Nerve"}, {"x": 600, "y": 500, "label": "Optic Nerve"}."#
        let (clean, parts) = CoordinateScrubber.scrub(text)
        #expect(clean == "This image shows a cross-section of the brain, highlighting the optic chiasm and optic nerves. The optic nerves carry visual information.")
        #expect(parts == [Pointer(x: 400, y: 200, label: "Optic Chiasm"), Pointer(x: 300, y: 500, label: "Optic Nerve"),
                          Pointer(x: 600, y: 500, label: "Optic Nerve")])
    }

    @Test func removesInlinePositionsButKeepsOtherNumbers() {
        #expect(CoordinateScrubber.scrub("The liver (x: 640, y: 420) filters blood.").text == "The liver filters blood.")
        #expect(CoordinateScrubber.scrub("The heart (320, 410) pumps blood.").text == "The heart pumps blood.")
        #expect(CoordinateScrubber.scrub("It was built between 1990, 2000 and later.").text == "It was built between 1990, 2000 and later.")
        #expect(CoordinateScrubber.scrub("Ohm's law: V = I × R, with R in ohms.").text == "Ohm's law: V = I × R, with R in ohms.")
    }
}

struct ScrubbedParsingTests {
    @Test func partsWrittenIntoTheTextBecomeParts() {
        let raw = #"{"speech": "The optic chiasm is where the nerves cross. Parts: {\"x\": 400, \"y\": 200, \"label\": \"Optic Chiasm\"}."}"#
        let response = ResponseParser.parse(raw, imageWidth: 1280, imageHeight: 900).response
        #expect(response.speech == "The optic chiasm is where the nerves cross.")
        #expect(response.parts == [Pointer(x: 400, y: 200, label: "Optic Chiasm")])
    }

    @Test func streamingTextStopsBeforeAHalfWrittenList() {
        #expect(CoordinateScrubber.partial(#"The optic chiasm. Parts: {"x": 40"#) == "The optic chiasm.")
    }
}

struct PartsRequestTests {
    @Test func partsRequestUsesTheFocusedPrompt() {
        var request = AskRequest(question: "The rotator cuff, four muscles around the shoulder.", screenshotJPEG: .init(),
                                 screenshotWidth: 1280, screenshotHeight: 870, context: ScreenContext())
        request.listParts = true
        #expect(Prompt.system(for: request) == Prompt.partsSystem)
        #expect(Prompt.userText(for: request).contains("It was just explained like this: \"The rotator cuff"))
        let parsed = ResponseParser.parse(#"{"parts": [{"x": 300, "y": 200, "label": "Supraspinatus"}]}"#, imageWidth: 1280, imageHeight: 870)
        #expect(parsed.response.parts == [Pointer(x: 300, y: 200, label: "Supraspinatus")])
    }
}

struct MostlyTextTests {
    private let marked = Rect(x: 0, y: 0, width: 800, height: 400)

    @Test func paragraphsAreText() {
        let lines = ["The rotator cuff is a group of four muscles", "that stabilise the shoulder joint and allow",
                     "the arm to rotate. Injuries are common in"].enumerated().map {
            TextBox(text: $0.element, center: Point(x: 400, y: Double(50 + $0.offset * 30)))
        }
        #expect(PartsTour.isMostlyText(lines, marked: marked))
    }

    @Test func figuresWithShortLabelsAreNot() {
        let labels = ["Supraspinatus", "Infraspinatus", "Teres minor", "Subscapularis", "Q1", "Q2", "Revenue"].enumerated().map {
            TextBox(text: $0.element, center: Point(x: Double(80 + $0.offset * 100), y: 200))
        }
        #expect(!PartsTour.isMostlyText(labels, marked: marked))
        #expect(!PartsTour.isMostlyText([], marked: marked))  // an unlabelled drawing
        // A labelled figure with a caption: lots of characters, mostly short labels.
        let captioned = labels + [TextBox(text: "Figure 3. The rotator cuff muscles seen from behind.", center: Point(x: 400, y: 380))]
            + (0..<14).map { TextBox(text: "Label \($0)", center: Point(x: Double(40 + $0 * 50), y: 300)) }
        #expect(!PartsTour.isMostlyText(captioned, marked: marked))
    }
}

struct FaceSnappingTests {
    // Three people, faces at x 300, 640, 1000 (y 200, 40 px wide).
    let faces: [(center: Point, width: Double)] = [
        (Point(x: 300, y: 200), 40), (Point(x: 640, y: 210), 40), (Point(x: 1000, y: 190), 40),
    ]

    @Test func twoNamesOnOnePersonGoToTwoPeople() {
        // From the 5 Oct log (in pixels): Rishikanth and Keerthy Suresh on the same person.
        let parts = [Pointer(x: 294, y: 341, label: "Keerthy Suresh"), Pointer(x: 248, y: 343, label: "Rishikanth"),
                     Pointer(x: 1050, y: 341, label: "Sananth")]
        let snapped = FaceSnapping.snap(parts, to: faces)
        #expect(Set(snapped.map { Int($0.x) }) == [300, 640, 1000])
        #expect(snapped[1].x == 300)   // leftmost name → leftmost face
        #expect(snapped[0].x == 640)
        #expect(snapped[2].x == 1000)
        #expect(snapped.allSatisfy { $0.y < 220 })  // on the faces
    }

    @Test func objectsStayWhereTheyAre() {
        let parts = [Pointer(x: 300, y: 250, label: "Keerthy Suresh"), Pointer(x: 640, y: 700, label: "Gramophone")]
        let snapped = FaceSnapping.snap(parts, to: [(Point(x: 300, y: 200), 40)])
        #expect(snapped[1] == parts[1])
        #expect(snapped[0].y == 200)
    }

    @Test func noFacesNoChange() {
        let parts = [Pointer(x: 10, y: 10, label: "Liver")]
        #expect(FaceSnapping.snap(parts, to: []) == parts)
    }

    @Test func fewerPeopleThanFacesUseTheClosestFaces() {
        let snapped = FaceSnapping.snap([Pointer(x: 980, y: 260, label: "Sananth")], to: faces)
        #expect(snapped[0].x == 1000)
    }
}

struct MadeUpLayoutTests {
    // qwen3.5:9b's reply for a diagonal solar-system picture (2026-10-06), 0–1000 scale:
    // every planet at y = 576, exactly 56 apart.
    private let planets = ["Mercury", "Venus", "Earth", "Mars", "Jupiter", "Saturn", "Uranus", "Neptune"]

    @Test func anEvenRowIsMadeUp() {
        let row = planets.enumerated().map { Pointer(x: 336 + Double($0.offset) * 56, y: 576, label: $0.element) }
        #expect(PartsTour.looksMadeUp([Pointer(x: 192, y: 408, label: "Sun")] + row))
        let column = planets.prefix(4).enumerated().map { Pointer(x: 500, y: 100 + Double($0.offset) * 80, label: $0.element) }
        #expect(PartsTour.looksMadeUp(column))
    }

    @Test func realPositionsAreNotMadeUp() {
        // Where the planets really are in that picture's close-up.
        let real = [(249, 450), (343, 411), (438, 358), (505, 296), (673, 320), (849, 247), (969, 171), (1076, 112)]
        #expect(!PartsTour.looksMadeUp(zip(planets, real).map { Pointer(x: Double($1.0), y: Double($1.1), label: $0) }))
        // Three in a row is too few to tell; uneven gaps on one line are a real layout.
        #expect(!PartsTour.looksMadeUp([Pointer(x: 100, y: 50, label: "A"), Pointer(x: 200, y: 50, label: "B"), Pointer(x: 300, y: 50, label: "C")]))
        #expect(!PartsTour.looksMadeUp([100, 160, 300, 330].map { Pointer(x: $0, y: 50, label: "\($0)") }))
    }
}

struct ObjectMarksTests {
    private let marked = Rect(x: 0, y: 0, width: 1280, height: 584)

    private func thing(_ x: Double, _ y: Double, _ width: Double, _ height: Double, fill: Double = 0.8) -> FoundObject {
        FoundObject(center: Point(x: x, y: y), width: width, height: height, fill: fill)
    }

    @Test func eachThingIsMarkedOnceLeftToRight() {
        let found = [
            thing(673, 320, 130, 128), thing(249, 450, 31, 29, fill: 0.77), thing(249, 450, 30, 28, fill: 0.79),
            thing(438, 356, 51, 76, fill: 0.59), thing(438, 358, 51, 50, fill: 0.79),  // Earth, seen twice
            thing(1103, 191, 138, 360, fill: 0.14),  // an orbit line
            thing(640, 292, 1280, 584),  // the whole background
            thing(20, 20, 4, 4),  // a speck
        ]
        let marks = ObjectMarks.merge(found, imageWidth: 1280, imageHeight: 584, marked: marked)
        #expect(marks.map(\.center.x) == [249, 438, 673])
        #expect(marks[0].fill == 0.79 && marks[1].height == 50)  // the most solid sighting
    }

    @Test func thingsOutsideWhatWasMarkedAreLeftOut() {
        let marks = ObjectMarks.merge([thing(300, 300, 40, 40), thing(1200, 300, 40, 40)], imageWidth: 1280, imageHeight: 584,
                                      marked: Rect(x: 200, y: 200, width: 400, height: 200))
        #expect(marks.map(\.center.x) == [300])
    }

    @Test func badgesSitAboveOrBelowTheThing() {
        #expect(ObjectMarks.badgeCenter(for: thing(673, 320, 130, 128)).y < 320 - 64)
        #expect(ObjectMarks.badgeCenter(for: thing(1076, 30, 69, 50)).y > 30 + 25)  // no room above
    }

    @Test func namedMarksBecomeStopsOnTheThings() {
        let objects = [thing(505, 296, 40, 40), thing(343, 411, 48, 49), thing(849, 247, 169, 99)]
        // A fish in the wallpaper (4) is "none"; 9 isn't a mark; Venus given twice keeps the first.
        let reply = #"{"1": "Mars", "2": "Venus", "3": "Saturn", "4": "none", "9": "Earth", "5": "Venus"}"#
        let marks = objects + [thing(1100, 300, 30, 12), thing(1150, 320, 30, 12)]
        let stops = ObjectMarks.placed(names: ["Sun", "Mars", "Venus", "Earth", "Saturn"], reply: reply, objects: marks)
        #expect(stops.map(\.label) == ["Mars", "Venus", "Saturn"])  // in the names' order
        #expect(stops[0] == Pointer(x: 505, y: 296, label: "Mars"))
        #expect(stops[1] == Pointer(x: 343, y: 411, label: "Venus"))
        #expect(ObjectMarks.placed(names: ["Mars"], reply: "no idea", objects: objects).isEmpty)
    }

    @Test func theMarksPromptListsTheNames() {
        var request = AskRequest(question: "The solar system.", screenshotJPEG: Data(), screenshotWidth: 1280, screenshotHeight: 584,
                                 context: ScreenContext())
        request.markNames = ["Sun", "Mercury"]
        request.markCount = 8
        #expect(Prompt.system(for: request) == Prompt.marksSystem)
        #expect(Prompt.userText(for: request).contains("Names: Sun, Mercury\nMarkers: 1–8."))
        // One key per mark, each a name or "none".
        let schema = OllamaProvider.schema(for: request)
        let properties = schema?["properties"] as? [String: Any]
        #expect(properties?.count == 8 && (schema?["required"] as? [String])?.contains("8") == true)
        #expect((properties?["3"] as? [String: Any])?["enum"] as? [String] == ["Sun", "Mercury", "none"])
    }
}
