import Testing
@testable import ClickBaitCore

struct ResponseParserTests {
    private func parse(_ raw: String, width: Int = 1280, height: Int = 831) -> ResponseParser.Result {
        ResponseParser.parse(raw, imageWidth: width, imageHeight: height)
    }

    @Test func parsesDocumentedShape() {
        let result = parse(#"{"speech": "Click Share.", "pointers": [{"x": 1180, "y": 42, "label": "Share"}]}"#)
        #expect(result.response == AssistantResponse(speech: "Click Share.", pointers: [Pointer(x: 1180, y: 42, label: "Share")]))
        #expect(!result.usedFallback)
        #expect(result.droppedPointers == 0)
    }

    @Test func toleratesCodeFencesAndLeadingText() {
        let raw = """
            Sure! Here's what to do:
            ```json
            {"speech": "Click Share.", "pointers": [{"x": 10, "y": 20, "label": "Share"}]}
            ```
            """
        #expect(parse(raw).response.pointers == [Pointer(x: 10, y: 20, label: "Share")])
    }

    @Test func skipsBracesInsideLeadingTextAndStrings() {
        let raw = #"Use {this}: {"speech": "Type {name} then click OK.", "pointers": []}"#
        #expect(parse(raw).response.speech == "Type {name} then click OK.")
    }

    @Test func acceptsQwenStyleXYArray() {
        // Real reply from qwen2.5vl:7b during step 5 testing.
        let result = parse(#"{"speech": "Click the Share button in the top right corner.", "pointers": [{"x": [1262, 50], "label": "Share button"}]}"#)
        #expect(result.response.pointers == [Pointer(x: 1262, y: 50, label: "Share button")])
    }

    @Test(arguments: [
        #"{"speech": "s", "pointers": [{"point_2d": [100, 200], "label": "A"}]}"#,
        #"{"speech": "s", "pointers": [{"point": [100, 200], "label": "A"}]}"#,
        #"{"speech": "s", "pointers": [{"bbox_2d": [80, 180, 120, 220], "label": "A"}]}"#,
        #"{"speech": "s", "pointers": [{"x": "100", "y": "200", "label": "A"}]}"#,
        #"{"speech": "s", "pointer": {"x": 100, "y": 200, "label": "A"}}"#,
        #"{"speech": "s", "points": [{"x": 100.0, "y": 200.0, "name": "A"}]}"#,
    ])
    func acceptsOtherCoordinateShapes(_ raw: String) {
        #expect(parse(raw).response.pointers == [Pointer(x: 100, y: 200, label: "A")])
    }

    @Test func dropsPointersWithoutCoordinatesOrFarOffImage() {
        let raw = #"{"speech": "s", "pointers": [{"label": "none"}, {"x": 5000, "y": 10, "label": "far"}, {"x": 5, "y": 6, "label": "ok"}, "junk"]}"#
        let result = parse(raw)
        #expect(result.response.pointers == [Pointer(x: 5, y: 6, label: "ok")])
        #expect(result.droppedPointers == 3)
    }

    @Test func clampsPointersJustOutsideTheImage() {
        // 1300 is within 3% of 1280: model rounding, not a wrong answer.
        let result = parse(#"{"speech": "s", "pointers": [{"x": 1300, "y": -10, "label": "edge"}]}"#)
        #expect(result.response.pointers == [Pointer(x: 1279, y: 0, label: "edge")])
    }

    @Test func keepsAtMostThreePointers() {
        let points = (1...5).map { #"{"x": \#($0), "y": \#($0), "label": "p\#($0)"}"# }.joined(separator: ",")
        let result = parse(#"{"speech": "s", "pointers": [\#(points)]}"#)
        #expect(result.response.pointers.map(\.label) == ["p1", "p2", "p3"])
        #expect(result.droppedPointers == 2)
    }

    @Test func booleansAreNotCoordinates() {
        #expect(parse(#"{"speech": "s", "pointers": [{"x": true, "y": false}]}"#).response.pointers.isEmpty)
    }

    @Test func plainTextFallsBackToSpeechOnly() {
        let result = parse("Click the blue Share button in the toolbar.")
        #expect(result.response == AssistantResponse(speech: "Click the blue Share button in the toolbar."))
        #expect(result.usedFallback)
    }

    @Test func truncatedJSONSalvagesTheSpeech() {
        let result = parse(#"{"speech": "Open the File menu.", "pointers": [{"x": 12, "y""#)
        #expect(result.response == AssistantResponse(speech: "Open the File menu."))
        #expect(result.usedFallback)
    }

    @Test func garbageFallsBackToApology() {
        #expect(parse("{{{ ]]] }").response.speech == ResponseParser.fallbackSpeech)
        #expect(parse("").response.speech == ResponseParser.fallbackSpeech)
    }

    @Test func missingSpeechUsesFallbackButKeepsPointers() {
        let result = parse(#"{"pointers": [{"x": 1, "y": 2, "label": "a"}]}"#)
        #expect(result.response.speech == ResponseParser.fallbackSpeech)
        #expect(result.response.pointers.count == 1)
    }
}

struct StreamingSpeechExtractorTests {
    private func run(_ chunks: [String]) -> (String, Bool) {
        var extractor = StreamingSpeechExtractor()
        let text = chunks.map { extractor.feed($0) }.joined()
        return (text, extractor.isComplete)
    }

    @Test func extractsSpeechFromOneChunk() {
        #expect(run([#"{"speech": "Click Share.", "pointers": []}"#]) == ("Click Share.", true))
    }

    @Test func streamsAsCharactersArrive() {
        var extractor = StreamingSpeechExtractor()
        #expect(extractor.feed(#"{"spe"#) == "")
        #expect(extractor.feed(#"ech": "Cli"#) == "Cli")
        #expect(extractor.feed(#"ck Sh"#) == "ck Sh")
        #expect(!extractor.isComplete)
        #expect(extractor.feed(#"are.", "pointers": [{"x": 1"#) == "are.")
        #expect(extractor.isComplete)
        #expect(extractor.feed(#", "speech": "again"}"#) == "")
    }

    @Test func everySplitPointGivesTheSameText() {
        let json = #"{"speech": "Say \"hi\" \\ then\nclick café 👋.", "pointers": []}"#
        let expected = "Say \"hi\" \\ then\nclick café 👋."
        let scalars = Array(json.unicodeScalars)
        for split in 0...scalars.count {
            let a = String(String.UnicodeScalarView(scalars[..<split]))
            let b = String(String.UnicodeScalarView(scalars[split...]))
            #expect(run([a, b]).0 == expected, "split at \(split)")
        }
    }

    @Test func decodesUnicodeEscapesSplitAcrossChunks() {
        // "é" and "👋" (a surrogate pair) as \u escapes, cut mid-escape.
        #expect(run([#"{"speech": "caf\u00"#, #"e9 \ud83d"#, #"\udc4b"}"#]).0 == "café 👋")
    }

    @Test func ignoresSpeechAppearingAsAValue() {
        #expect(run([#"{"label": "speech", "speech": "Real."}"#]).0 == "Real.")
    }

    @Test func toleratesWhitespaceAndLeadingChatter() {
        #expect(run(["Here you go:\n```json\n{ \"speech\"  :\n  \"Hi.\" }"]).0 == "Hi.")
    }

    @Test func nonStringSpeechYieldsNothing() {
        #expect(run([#"{"speech": null}"#]) == ("", true))
    }
}

struct CodeFieldTests {
    private func parse(_ raw: String) -> ResponseParser.Result {
        ResponseParser.parse(raw, imageWidth: 1280, imageHeight: 800)
    }

    @Test func codeFieldIsParsedAndShownAsABlock() {
        let raw = #"{"speech": "Run this in Terminal:", "pointers": [], "code": "python3 --version", "language": "bash"}"#
        let response = parse(raw).response
        #expect(response.code == "python3 --version")
        #expect(response.language == "bash")
        #expect(response.displayText == "Run this in Terminal:\n```bash\npython3 --version\n```")
        #expect(MessageFormat.spokenText(response.displayText) == "Run this in Terminal:")
    }

    @Test func codeRepeatedInsideSpeechIsShownOnce() {
        // Real qwen2.5vl:7b reply: the code both fenced in "speech" and in "code".
        let raw = #"{"speech": "To print 'hello world' in Python, you can use the following code:\n\n```python\nprint('hello world')\n```", "pointers": [], "code": "print('hello world')", "language": "python"}"#
        let blocks = MessageFormat.segments(parse(raw).response.displayText).filter {
            if case .code = $0 { return true } else { return false }
        }
        #expect(blocks == [.code(language: "python", code: "print('hello world')")])
    }

    @Test func codeAsLinesAndEmptyCode() {
        #expect(parse(#"{"speech": "s", "code": ["a = 1", "print(a)"]}"#).response.code == "a = 1\nprint(a)")
        #expect(parse(#"{"speech": "s", "code": ""}"#).response.code == nil)
        #expect(parse(#"{"speech": "s"}"#).response.displayText == "s")
    }
}
