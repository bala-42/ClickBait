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
