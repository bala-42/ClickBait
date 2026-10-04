import Testing
@testable import ClickBaitCore

struct PartsTourTests {
    private let marked = Rect(x: 100, y: 100, width: 600, height: 400)

    @Test func parsesPartsAndListsThemInTheChat() {
        let raw = #"{"speech": "The rotator cuff, four muscles that hold the shoulder.", "parts": [{"x": 300, "y": 200, "label": "Supraspinatus"}, {"x": 450, "y": 320, "label": "Infraspinatus"}]}"#
        let response = ResponseParser.parse(raw, imageWidth: 800, imageHeight: 600).response
        #expect(response.parts.map(\.label) == ["Supraspinatus", "Infraspinatus"])
        #expect(response.displayText.hasSuffix("**Parts:** Supraspinatus · Infraspinatus"))
    }

    @Test func toursSpreadOutPartsInsideTheMarkedArea() {
        let parts = [Pointer(x: 200, y: 150, label: "Subscapularis"), Pointer(x: 400, y: 200, label: "Supraspinatus"),
                     Pointer(x: 550, y: 350, label: "Infraspinatus"), Pointer(x: 650, y: 450, label: "Teres minor")]
        #expect(PartsTour.plan(parts, marked: marked)?.count == 4)
    }

    @Test func dropsOutsidersAndDuplicates() {
        let parts = [Pointer(x: 200, y: 150, label: "A"), Pointer(x: 900, y: 150, label: "Far away"),
                     Pointer(x: 500, y: 400, label: "B"), Pointer(x: 520, y: 380, label: "b")]
        #expect(PartsTour.plan(parts, marked: marked)?.map(\.label) == ["A", "B"])
    }

    @Test func pileUpsAreListedNotToured() {
        // Real failure mode: a model that can't place parts stacks them in one spot.
        let parts = (0..<5).map { Pointer(x: 400 + Double($0) * 5, y: 300, label: "Part \($0)") }
        #expect(PartsTour.plan(parts, marked: marked) == nil)
        #expect(PartsTour.plan([Pointer(x: 300, y: 300, label: "Only one")], marked: marked) == nil)
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
