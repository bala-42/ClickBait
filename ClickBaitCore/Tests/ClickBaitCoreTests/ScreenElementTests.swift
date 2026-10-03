import Foundation
import Testing
@testable import ClickBaitCore

struct ScreenElementTests {
    // 1512×982 pt display shown as a 1280×831 screenshot.
    private let geometry = ScreenGeometry(imageWidth: 1280, imageHeight: 831,
                                          displayFrame: Rect(x: 0, y: 0, width: 1512, height: 982), primaryDisplayHeight: 982)

    @Test func listsElementsOnScreenWithImageCenters() {
        let elements = [
            ScreenElement(role: "AXMenuItem", label: "Show Path Bar", frame: Rect(x: 300, y: 200, width: 200, height: 22)),
            ScreenElement(role: "AXButton", label: "Off screen", frame: Rect(x: 3000, y: 10, width: 20, height: 20)),
            ScreenElement(role: "AXRow", label: "Applications", frame: Rect(x: 10, y: 300, width: 150, height: 28)),
        ]
        let listed = PromptElement.list(elements, geometry: geometry)
        #expect(listed.map(\.id) == [1, 2])
        #expect(listed[0].kind == "menu item")
        #expect(listed[0].x == 339 && listed[0].y == 179)  // (400, 211) pt × 1280/1512
        #expect(listed[1].label == "Applications")
        #expect(listed[0].line == #"1: menu item "Show Path Bar" at (339, 179)"#)
    }

    @Test func pointerByElementIdUsesTheExactCenter() {
        let elements = [PromptElement(id: 1, kind: "button", label: "Share", x: 980, y: 52),
                        PromptElement(id: 2, kind: "menu item", label: "Show Path Bar", x: 339, y: 179)]
        let raw = #"{"speech": "It's in the View menu.", "pointers": [{"element": 2, "label": "Show Path Bar"}]}"#
        let result = ResponseParser.parse(raw, imageWidth: 1280, imageHeight: 831, elements: elements)
        #expect(result.response.pointers == [Pointer(x: 339, y: 179, label: "Show Path Bar")])
    }

    @Test func elementIdWinsOverRoughCoordinatesAndUnknownIdsFallBack() {
        let elements = [PromptElement(id: 1, kind: "button", label: "Share", x: 980, y: 52)]
        let both = #"{"speech": "s", "pointers": [{"element": 1, "x": 900, "y": 80}]}"#
        #expect(ResponseParser.parse(both, imageWidth: 1280, imageHeight: 831, elements: elements).response.pointers
                == [Pointer(x: 980, y: 52, label: "Share")])
        let unknown = #"{"speech": "s", "pointers": [{"element": 9, "x": 500, "y": 400, "label": "A"}]}"#
        #expect(ResponseParser.parse(unknown, imageWidth: 1280, imageHeight: 831, elements: elements).response.pointers
                == [Pointer(x: 500, y: 400, label: "A")])
        let neither = #"{"speech": "s", "pointers": [{"element": 9}]}"#
        #expect(ResponseParser.parse(neither, imageWidth: 1280, imageHeight: 831, elements: elements).response.pointers.isEmpty)
    }

    @Test func promptListsTheElements() {
        let request = AskRequest(question: "where's share", screenshotJPEG: Data(), screenshotWidth: 1280, screenshotHeight: 831,
                                 context: ScreenContext(), elements: [PromptElement(id: 1, kind: "button", label: "Share", x: 980, y: 52)])
        #expect(Prompt.userText(for: request).contains(#"1: button "Share" at (980, 52)"#))
    }

    @Test func coordinatesForAListedNameSnapToItsCenter() {
        // Real qwen2.5vl:7b reply: the View menu's x with Show Path Bar's y.
        let elements = [PromptElement(id: 5, kind: "menu", label: "View", x: 200, y: 12),
                        PromptElement(id: 13, kind: "menu item", label: "Show Path Bar", x: 230, y: 140)]
        let raw = #"{"speech": "s", "pointers": [{"x": 200, "y": 140, "label": "Show Path Bar"}]}"#
        #expect(ResponseParser.parse(raw, imageWidth: 1280, imageHeight: 800, elements: elements).response.pointers
                == [Pointer(x: 230, y: 140, label: "Show Path Bar")])
        // Far away or a different name: left alone.
        let far = #"{"speech": "s", "pointers": [{"x": 900, "y": 600, "label": "Show Path Bar"}, {"x": 210, "y": 30, "label": "Edit"}]}"#
        #expect(ResponseParser.parse(far, imageWidth: 1280, imageHeight: 800, elements: elements).response.pointers
                == [Pointer(x: 900, y: 600, label: "Show Path Bar"), Pointer(x: 210, y: 30, label: "Edit")])
    }

    @Test func locateRequestsUseTheCloseUpPrompt() {
        let request = AskRequest(question: "where's the share button", screenshotJPEG: Data(), screenshotWidth: 1120, screenshotHeight: 800,
                                 context: ScreenContext(), locate: "Share")
        #expect(Prompt.system(for: request) == Prompt.locateSystem)
        #expect(Prompt.userText(for: request).contains(#"Find: "Share""#))
        let normal = AskRequest(question: "q", screenshotJPEG: Data(), screenshotWidth: 1, screenshotHeight: 1, context: ScreenContext())
        #expect(Prompt.system(for: normal) == Prompt.system)
    }

    @Test func longListsKeepWhatTheQuestionNamesAndOpenMenus() {
        var elements = (0..<120).map { ScreenElement(role: "AXButton", label: "Button \($0)", frame: Rect(x: Double($0 * 10), y: 100, width: 8, height: 8)) }
        elements.append(ScreenElement(role: "AXMenuItem", label: "Copy", frame: Rect(x: 500, y: 300, width: 100, height: 20)))
        elements.append(ScreenElement(role: "AXRow", label: "Show Path Bar", frame: Rect(x: 600, y: 600, width: 100, height: 20)))
        elements.append(ScreenElement(role: "AXButton", label: "Button 3", frame: Rect(x: 30, y: 100, width: 8, height: 8)))  // duplicate
        let listed = PromptElement.list(elements, geometry: geometry, question: "where is show path bar?", limit: 50)
        #expect(listed.count == 50)
        #expect(listed.contains { $0.label == "Show Path Bar" })
        #expect(listed.contains { $0.label == "Copy" })
        #expect(listed.filter { $0.label == "Button 3" }.count == 1)
        #expect(listed.map(\.id) == Array(1...50))
    }
}
