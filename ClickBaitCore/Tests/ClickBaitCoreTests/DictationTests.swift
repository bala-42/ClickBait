import Foundation
import Testing
@testable import ClickBaitCore

struct DictationTests {
    // MARK: Hotkey

    @Test func fnControlHoldsAndReleases() {
        var detector = ChordDetector()
        #expect(detector.modifiersChanged(to: [.control]) == [])
        #expect(detector.modifiersChanged(to: [.control, .function]) == [.dictatePressed])
        #expect(detector.modifiersChanged(to: [.control]) == [.dictateReleased])
    }

    @Test func extraModifierOrKeyCancels() {
        var detector = ChordDetector()
        _ = detector.modifiersChanged(to: [.control, .function])
        #expect(detector.modifiersChanged(to: [.control, .function, .shift]) == [.dictateCancelled])
        _ = detector.modifiersChanged(to: [])
        _ = detector.modifiersChanged(to: [.control, .function])
        #expect(detector.keyPressed() == [.dictateCancelled])
    }

    @Test func askStillWorks() {
        var detector = ChordDetector()
        _ = detector.modifiersChanged(to: [.control])
        #expect(detector.modifiersChanged(to: [.control, .option]) == [.askPressed])
        #expect(detector.modifiersChanged(to: []) == [.askReleased])
    }

    // MARK: Hints

    @Test func hintsKeepNamesAndCaretText() {
        let hints = Dictation.hints(windowTitle: "Atlas launch – Mail", labels: ["Send", "Reply All", "qwen3.5"],
                                    textBeforeCaret: "Hi Priya,")
        #expect(hints.hasPrefix("Atlas, Mail, qwen3.5, Priya."))
        #expect(hints.hasSuffix("Hi Priya,"))
        #expect(!hints.contains("Send"))
    }

    @Test func hintsStayShort() {
        let labels = (1...200).map { "Label\($0)" }
        let hints = Dictation.hints(windowTitle: nil, labels: labels, textBeforeCaret: String(repeating: "word ", count: 100))
        #expect(hints.count <= Dictation.maxHintCharacters)
        #expect(Dictation.hints(windowTitle: nil, labels: [], textBeforeCaret: nil) == "")
    }

    // MARK: Style and tidy-up

    @Test func styleFromApp() {
        #expect(Dictation.Style(app: "Messages") == .casual)
        #expect(Dictation.Style(app: "Mail") == .written)
        #expect(Dictation.Style(app: "Terminal") == .code)
        #expect(Dictation.Style(app: "Finder") == .plain)
        #expect(Dictation.Style(app: nil) == .plain)
    }

    @Test func tidyPromptIsTextOnly() {
        var ask = AskRequest(question: "", screenshotJPEG: Data(), screenshotWidth: 0, screenshotHeight: 0,
                             context: ScreenContext(appName: "Mail"), selectedText: nil)
        ask.dictation = "um see you at three"
        ask.screenWords = "Priya."
        #expect(Prompt.system(for: ask) == Prompt.dictationSystem)
        let text = Prompt.userText(for: ask)
        #expect(text.contains("Dictated: um see you at three"))
        #expect(text.contains("Screen words: Priya."))
        #expect(text.contains("App: Mail"))
        #expect(OllamaProvider.schema(for: ask) != nil)
    }

    @Test func tidyReplyUsedWhenSane() {
        #expect(Dictation.parseTidy(#"{"text": "See you at 3."}"#, raw: "um see you at three") == "See you at 3.")
    }

    @Test func tidyFallsBackToRaw() {
        let raw = "what time is the meeting tomorrow"
        #expect(Dictation.parseTidy(nil, raw: raw) == raw)
        #expect(Dictation.parseTidy("not json", raw: raw) == raw)
        #expect(Dictation.parseTidy(#"{"text": ""}"#, raw: raw) == raw)
        let answered = #"{"text": "The meeting is at 10 am tomorrow in room 4, and you should bring the quarterly report with you."}"#
        #expect(Dictation.parseTidy(answered, raw: raw) == raw)
    }

    @Test func tidyLimitGrowsWithLength() {
        #expect(Dictation.tidyLimit(for: "hi") == .milliseconds(3_013))
        #expect(Dictation.tidyLimit(for: String(repeating: "a", count: 300)) == .milliseconds(5_000))
    }

    // MARK: Putting it in

    @Test func spaceBeforeWhenItWouldRunOn() {
        #expect(Dictation.joined("see you", after: "Hi Priya,") == " see you")
        #expect(Dictation.joined("see you", after: "Hi ") == "see you")
        #expect(Dictation.joined("see you", after: nil) == "see you")
        #expect(Dictation.joined(", thanks", after: "ok") == ", thanks")
        #expect(Dictation.joined("quoted", after: "(") == "quoted")
    }

    @Test func neverPastesIntoPasswords() {
        #expect(Dictation.delivery(role: "AXTextField", subrole: nil, editable: true, sameApp: true) == .paste)
        #expect(Dictation.delivery(role: "AXTextField", subrole: "AXSecureTextField", editable: true, sameApp: true) == .copyOnly)
        #expect(Dictation.delivery(role: "AXButton", subrole: nil, editable: false, sameApp: true) == .copyOnly)
        #expect(Dictation.delivery(role: "AXTextArea", subrole: nil, editable: true, sameApp: false) == .copyOnly)
    }
}
