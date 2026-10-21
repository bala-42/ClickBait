import Testing
@testable import ClickBaitCore

struct NoteFolderTests {
    private let notes: [(name: String, text: String)] = [
        ("work", "# Projects\n- Atlas launch: 3 November\n- Orion review on Fridays\n\nWifi password is hunter22"),
        ("home", "* Dentist appointment Tuesday\n> Passport K1234567 renew in March"),
    ]

    @Test func onlyMatchingLinesWithTheirFile() {
        #expect(NoteFolder.relevant(to: "when is the Atlas launch?", notes: notes) == ["Atlas launch: 3 November (work)"])
        #expect(NoteFolder.relevant(to: "dentist?", notes: notes) == ["Dentist appointment Tuesday (home)"])
    }

    @Test func headingsSecretsAndIDsStayOut() {
        #expect(NoteFolder.relevant(to: "projects", notes: notes).isEmpty)      // a heading only
        #expect(NoteFolder.relevant(to: "wifi password", notes: notes).isEmpty)  // a secret
        #expect(NoteFolder.relevant(to: "renew passport", notes: notes).isEmpty) // an ID number
    }

    @Test func nothingForAnUnrelatedQuestionAndABudget() {
        #expect(NoteFolder.block(for: "what's the weather", notes: notes) == nil)
        let long = (1...200).map { "- launch item \($0) with some longer words" }.joined(separator: "\n")
        let picked = NoteFolder.relevant(to: "launch", notes: [("big", long)])
        #expect(!picked.isEmpty && picked.joined().count <= NoteFolder.promptBudget)
    }

    @Test func blockReadsAsTheUsersNotes() {
        let block = NoteFolder.block(for: "Orion review", notes: notes)
        #expect(block?.hasPrefix("From the user's notes") == true)
        #expect(block?.contains("- Orion review on Fridays (work)") == true)
    }
}
