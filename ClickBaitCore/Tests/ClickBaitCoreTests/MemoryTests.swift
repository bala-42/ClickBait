import Foundation
import Testing
@testable import ClickBaitCore

/// C5: remembered facts — the user's words, newest wins, secrets refused, small in the prompt.
struct MemoryTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
        return calendar
    }
    private var oct20: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 9))! }

    @Test func theUsersWords() {
        #expect(Memory.command(in: "remember my team is Atlas") == .remember("My team is Atlas"))
        #expect(Memory.command(in: "Remember that I use Chrome.") == .remember("I use Chrome"))
        #expect(Memory.command(in: "don't forget my standup is at 10") == .remember("My standup is at 10"))
        #expect(Memory.command(in: "keep in mind I'm vegetarian") == .remember("I'm vegetarian"))
        #expect(Memory.command(in: "from now on, use Chrome") == .remember("From now on, use Chrome"))
        #expect(Memory.command(in: "note that I prefer metric units") == .remember("I prefer metric units"))
        #expect(Memory.command(in: "forget my team") == .forget("My team"))
        #expect(Memory.command(in: "forget that I use Chrome") == .forget("I use Chrome"))
    }

    @Test func questionsAreNotOrders() {
        #expect(Memory.command(in: "do you remember my team?") == nil)
        #expect(Memory.command(in: "what does remember mean") == nil)
        #expect(Memory.command(in: "note that down") == nil)
        #expect(Memory.command(in: "why do I always forget") == nil)
    }

    @Test func newestWinsAboutTheSameThing() {
        var memory = Memory(file: "")
        memory.add("My team is Atlas", on: oct20, calendar: calendar)
        memory.add("I use Chrome", on: oct20, calendar: calendar)
        memory.add("My team is Orion", on: oct20, calendar: calendar)
        memory.add("I use Safari now", on: oct20, calendar: calendar)
        #expect(memory.notes.map(\.text) == ["My team is Orion", "I use Safari now"])
    }

    @Test func secretsAreRefused() {
        var memory = Memory(file: "")
        #expect(memory.add("My password is hunter2", on: oct20) == .refusedSecret)
        #expect(memory.add("card 4111 1111 1111 1111", on: oct20) == .refusedSecret)
        #expect(memory.add("key sk-proj-A1b2C3d4E5f6G7h8I9j0K1l2", on: oct20) == .refusedSecret)
        #expect(memory.add("My PIN code is 1234", on: oct20) == .refusedSecret)
        #expect(memory.notes.isEmpty)
        #expect(memory.add("My phone ends in 4821", on: oct20) == .saved("My phone ends in 4821"))
    }

    @Test func forgetting() {
        var memory = Memory(file: "")
        memory.add("My team is Atlas", on: oct20)
        memory.add("I use Chrome", on: oct20)
        #expect(memory.forget("my team") == 1)
        #expect(memory.forget("I use Chrome") == 1)
        #expect(memory.notes.isEmpty)
    }

    @Test func theFileRoundTripsAndIgnoresOtherLines() {
        var memory = Memory(file: "")
        memory.add("My team is Atlas", on: oct20, calendar: calendar)
        let reread = Memory(file: memory.file + "\nsome note I typed by hand\n- not a date: x\n")
        #expect(reread.notes == [Memory.Note(date: "2026-10-20", text: "My team is Atlas")])
        #expect(memory.file.contains("- 2026-10-20: My team is Atlas"))
    }

    @Test func atMostThirty() {
        var memory = Memory(file: "")
        for i in 0..<40 { memory.add("Fact number \(i) here", on: oct20) }
        #expect(memory.notes.count == Memory.capacity)
        #expect(memory.notes.first?.text == "Fact number 10 here")
    }

    @Test func thePromptGetsMatchingLinesFirstWithinBudget() {
        var memory = Memory(file: "")
        for i in 0..<30 { memory.add("Unrelated detail \(i) about gardening tomatoes", on: oct20) }
        memory.add("My team is Atlas", on: oct20)
        let lines = memory.relevant(to: "who is on my team")
        #expect(lines.first == "My team is Atlas")
        #expect(lines.joined().count <= Memory.promptBudget)
        #expect(Memory(file: "").block(for: "anything") == nil)
    }

    @Test func aPlainAskCarriesTheBlock() {
        var memory = Memory(file: "")
        memory.add("I use Chrome", on: oct20)
        var ask = AskRequest(question: "open my browser", screenshotJPEG: Data(), screenshotWidth: 640, screenshotHeight: 400,
                             context: ScreenContext())
        ask.remembered = memory.block(for: ask.question)
        #expect(Prompt.userText(for: ask).contains("What the user asked ClickBait to remember (their own facts; use them when they fit):\n- I use Chrome"))
        #expect(Prompt.userText(for: ask).hasSuffix("The user said: open my browser"))
    }
}
