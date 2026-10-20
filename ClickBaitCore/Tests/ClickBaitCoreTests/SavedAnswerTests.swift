import Foundation
import Testing
@testable import ClickBaitCore

/// C5: saved answers — a safe dated file name, the chat as Markdown, no overwrites.
struct SavedAnswerTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
        return calendar
    }
    private var oct20: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 9))! }

    @Test func fileNames() {
        #expect(SavedAnswer.fileName(question: "how do I zip a folder?", date: oct20, calendar: calendar) == "2026-10-20 how do I zip a folder.md")
        #expect(SavedAnswer.fileName(question: "a/b: c\\d", date: oct20, calendar: calendar) == "2026-10-20 a b c d.md")
        #expect(SavedAnswer.fileName(question: "", date: oct20, calendar: calendar) == "2026-10-20 answer.md")
        #expect(SavedAnswer.fileName(question: String(repeating: "x", count: 200), date: oct20, calendar: calendar).count == 11 + 60 + 3)
    }

    @Test func theChatAsMarkdown() {
        let text = SavedAnswer.markdown([(.user, "how do I zip a folder?"), (.assistant, "Right-click it ▸ Compress."),
                                         (.user, "and unzip?"), (.assistant, "Double-click the .zip.")],
                                        date: oct20, calendar: calendar)
        #expect(text.hasPrefix("# how do I zip a folder?\n\n_Saved from ClickBait on 2026-10-20._\n\n**You:** how do I zip a folder?"))
        #expect(text.contains("Right-click it ▸ Compress.\n\n**You:** and unzip?\n\nDouble-click the .zip."))
    }

    @Test func neverOverwrites() {
        #expect(SavedAnswer.unique("a.md", existing: []) == "a.md")
        #expect(SavedAnswer.unique("a.md", existing: ["a.md", "a 2.md"]) == "a 3.md")
    }
}
