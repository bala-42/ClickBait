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

    @Test func byMeaningWithoutASharedWord() {
        // "teeth cleaning" shares no word with the dentist line; nomic's scores pick it.
        let similarity = ["Dentist appointment Tuesday": 0.62, "Atlas launch: 3 November": 0.44, "Orion review on Fridays": 0.48]
        #expect(NoteFolder.relevant(to: "when's my teeth cleaning", notes: notes, similarity: similarity) == ["Dentist appointment Tuesday (home)"])
        // Secrets stay out however close they are.
        #expect(NoteFolder.relevant(to: "internet login", notes: notes, similarity: ["Wifi password is hunter22": 0.9]).isEmpty)
    }
}
