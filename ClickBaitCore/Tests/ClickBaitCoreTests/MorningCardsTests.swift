import Foundation
import Testing
@testable import ClickBaitCore

struct MorningCardsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func dueOncePerDayAfterFive() {
        #expect(!MorningCards.isDue(now: date(21, 4), lastShown: nil, calendar: calendar))      // too early
        #expect(MorningCards.isDue(now: date(21, 8), lastShown: nil, calendar: calendar))
        #expect(MorningCards.isDue(now: date(21, 8), lastShown: date(20, 9), calendar: calendar)) // yesterday
        #expect(!MorningCards.isDue(now: date(21, 15), lastShown: date(21, 8), calendar: calendar)) // already today
    }

    @Test func briefListsTheDayAndNothingWhenEmpty() throws {
        #expect(MorningCards.brief(reminders: [], events: [], facts: [], now: date(21, 8), calendar: calendar) == nil)
        let brief = try #require(MorningCards.brief(
            reminders: [.init(title: "Pay rent", time: nil)],
            events: [.init(title: "Atlas standup", time: date(21, 9, 30))],
            facts: ["My team is Atlas"], now: date(21, 8), calendar: calendar))
        #expect(brief.contains("Wednesday 21 October"))
        #expect(brief.contains("- Atlas standup (09:30)"))
        #expect(brief.contains("- Pay rent"))
        #expect(brief.contains("- My team is Atlas"))
    }

    @Test func greetingRepliesAndThePlainOne() {
        #expect(MorningCards.greeting(from: #"{"text": "  Good morning, Balaji. Atlas standup is at 09:30.  "}"#) == "Good morning, Balaji. Atlas standup is at 09:30.")
        #expect(MorningCards.greeting(from: #"{"text": ""}"#) == nil)
        #expect(MorningCards.greeting(from: "no json") == nil)
        let long = #"{"text": "One sentence here. "# + String(repeating: "word ", count: 80) + #""}"#
        #expect(MorningCards.greeting(from: long) == "One sentence here.")  // cut at a sentence
        let plain = MorningCards.plainGreeting(name: "Balaji", reminders: [.init(title: "Pay rent", time: nil)],
                                               events: [.init(title: "Atlas standup", time: date(21, 9, 30))], now: date(21, 8), calendar: calendar)
        #expect(plain == "Good morning, Balaji. You have Atlas standup at 09:30. Pay rent is due today.")
        #expect(MorningCards.plainGreeting(name: nil, reminders: [], events: [], now: date(21, 8), calendar: calendar) == "Good morning. Nothing on your calendar today.")
    }

    @Test func requestUsesTheMorningPromptTextOnly() {
        var ask = AskRequest(question: "Good morning", screenshotJPEG: Data(), screenshotWidth: 0, screenshotHeight: 0,
                             context: ScreenContext(appName: nil), selectedText: nil)
        ask.morningBrief = "Today is Wednesday."
        #expect(Prompt.system(for: ask) == Prompt.morningSystem)
    }
}
