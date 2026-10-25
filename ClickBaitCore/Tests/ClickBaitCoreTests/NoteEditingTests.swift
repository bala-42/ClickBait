import Testing
@testable import ClickBaitCore

/// The shelf note's lists, as in Notes (2026-10-25).
struct NoteEditingTests {
    @Test func returnCarriesTheListOn() throws {
        let edit = try #require(NoteEditing.newline(in: "• milk", at: 6))
        #expect(edit == .init(text: "• milk\n• ", caret: 9))
        let box = try #require(NoteEditing.newline(in: "☑ call mum", at: 10))
        #expect(box.text == "☑ call mum\n☐ ")  // the next one starts unticked
        let indented = try #require(NoteEditing.newline(in: "    • eggs", at: 10))
        #expect(indented.text == "    • eggs\n    • ")
        #expect(NoteEditing.newline(in: "plain words", at: 11) == nil)
    }

    @Test func returnOnAnEmptyItemEndsTheList() throws {
        let edit = try #require(NoteEditing.newline(in: "• milk\n• ", at: 9))
        #expect(edit == .init(text: "• milk\n", caret: 7))
    }

    @Test func theBulletButtonWorksOnTheCaretsLine() {
        let text = "first\nsecond\nthird"
        #expect(NoteEditing.toggleBullet(in: text, at: 8) == .init(text: "first\n• second\nthird", caret: 10))
        #expect(NoteEditing.toggleBullet(in: "first\n• second\nthird", at: 10).text == text)
        #expect(NoteEditing.toggleCheckbox(in: "buy bread", at: 0).text == "☐ buy bread")
        #expect(NoteEditing.toggleCheckbox(in: "☑ buy bread", at: 5).text == "buy bread")
    }

    @Test func tabIndentsListLines() throws {
        #expect(try #require(NoteEditing.indent(in: "• a\n• b", at: 6, outdent: false)).text == "• a\n    • b")
        #expect(try #require(NoteEditing.indent(in: "• a\n    • b", at: 10, outdent: true)).text == "• a\n• b")
        #expect(NoteEditing.indent(in: "plain", at: 2, outdent: false) == nil)
    }

    @Test func aClickTicksTheBox() {
        #expect(NoteEditing.tick(in: "☐ water plants", at: 0) == "☑ water plants")
        #expect(NoteEditing.tick(in: "x\n  ☑ done", at: 4) == "x\n  ☐ done")
        #expect(NoteEditing.tick(in: "☐ water plants", at: 3) == nil)
        #expect(NoteEditing.tick(in: "say ☐ here", at: 4) == nil)  // not the line's own box
    }

    @Test func droppedTextGoesOnANewLine() {
        #expect(NoteEditing.adding("https://apple.com", to: "links:") == "links:\nhttps://apple.com")
        #expect(NoteEditing.adding("  hi \n", to: "") == "hi")
        #expect(NoteEditing.adding("", to: "keep") == "keep")
    }
}
