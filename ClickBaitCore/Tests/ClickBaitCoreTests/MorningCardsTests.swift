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

    @Test func repliesAreTrimmedCappedAndDeduped() {
        let reply = #"{"cards": ["draft the Atlas agenda", "Draft the Atlas agenda!", "", "Pay rent", "Plan the day", "A request that is far too long to fit a card pill"]}"#
        // The repeat (only "!" differs) and the empty and too-long ones go; at most three stay.
        #expect(MorningCards.parse(reply) == ["Draft the Atlas agenda", "Pay rent", "Plan the day"])
        #expect(MorningCards.parse("no json") == nil)
    }

    @Test func requestUsesTheMorningPromptTextOnly() {
        var ask = AskRequest(question: "Good morning", screenshotJPEG: Data(), screenshotWidth: 0, screenshotHeight: 0,
                             context: ScreenContext(appName: nil), selectedText: nil)
        ask.morningBrief = "Today is Wednesday."
        #expect(Prompt.system(for: ask) == Prompt.morningSystem)
    }
}
