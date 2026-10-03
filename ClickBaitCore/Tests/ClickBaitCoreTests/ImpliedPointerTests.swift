import Testing
@testable import ClickBaitCore

struct ImpliedPointerTests {
    private let elements = [
        PromptElement(id: 1, kind: "button", label: "Share", x: 1160, y: 60),
        PromptElement(id: 2, kind: "button", label: "New Note", x: 300, y: 60),
        PromptElement(id: 3, kind: "button", label: "New", x: 260, y: 60),
        PromptElement(id: 4, kind: "row", label: "Applications", x: 72, y: 266),
        PromptElement(id: 5, kind: "button", label: "OK", x: 600, y: 500),
    ]

    @Test func takesTheNamedElementForWhereQuestions() {
        // Real qwen2.5vl:7b reply shape: names it, no pointers.
        let pointer = ImpliedPointer.find(question: "how do I make a new note",
                                          speech: "Click the 'New Note' button at the bottom left.", elements: elements)
        #expect(pointer == Pointer(x: 300, y: 60, label: "New Note"))
    }

    @Test func prefersTheLongestNameInPlainSpeech() {
        let pointer = ImpliedPointer.find(question: "where can I make a new note?",
                                          speech: "Use the New Note button in the toolbar.", elements: elements)
        #expect(pointer?.label == "New Note")
        #expect(ImpliedPointer.find(question: "where is applications", speech: "It's Applications, in the sidebar.",
                                    elements: elements)?.label == "Applications")
    }

    @Test func onlyForLocatingQuestionsAndWholeWords() {
        #expect(ImpliedPointer.find(question: "what is a VPN", speech: "Share this with care.", elements: elements) == nil)
        // "Shared" isn't "Share"; "OK" is too short to trust.
        #expect(ImpliedPointer.find(question: "where are my shared files", speech: "They're in Shared, okay?", elements: elements) == nil)
        #expect(ImpliedPointer.find(question: "where do I click", speech: "Press OK.", elements: elements) == nil)
    }
}
