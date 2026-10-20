import Foundation
import Testing
@testable import ClickBaitCore

/// Today's date and "days until …" worked out for the model (2026-10-20: it said 30 days to
/// Christmas; it's 66).
struct DateFactsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
        return calendar
    }
    private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 15) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test func christmasFromTheTwentiethOfOctober() {
        let count = DateFacts.daysUntil("How many days until Christmas?", now: day(2026, 10, 20), calendar: calendar)
        #expect(count?.name == "Christmas" && count?.days == 66)
    }

    @Test func theLinesTheModelGets() {
        let lines = DateFacts.lines(for: "how many days till xmas", now: day(2026, 10, 20), calendar: calendar)
        #expect(lines == ["Today is Tuesday, 20 October 2026.",
                          "Christmas (Friday, 25 December 2026) is 66 days away, not counting today."])
    }

    @Test func pastThisYearMeansNextYear() {
        let count = DateFacts.daysUntil("days until halloween", now: day(2026, 11, 2), calendar: calendar)
        #expect(count?.days == 363)  // 31 October 2027
    }

    @Test func onTheDayItsToday() {
        let lines = DateFacts.lines(for: "how many days until christmas", now: day(2026, 12, 25), calendar: calendar)
        #expect(lines.last == "Christmas is today (Friday, 25 December 2026).")
    }

    @Test func longerNamesWinAndApostrophesWork() {
        #expect(DateFacts.daysUntil("how many days until christmas eve", now: day(2026, 10, 20), calendar: calendar)?.days == 65)
        #expect(DateFacts.daysUntil("how many days until new year's eve?", now: day(2026, 10, 20), calendar: calendar)?.name == "New Year's Eve")
        #expect(DateFacts.daysUntil("days left until New Year's", now: day(2026, 10, 20), calendar: calendar)?.days == 73)
    }

    @Test func writtenDates() {
        #expect(DateFacts.daysUntil("how many days to December 25th?", now: day(2026, 10, 20), calendar: calendar)?.days == 66)
        #expect(DateFacts.daysUntil("days until 1 november", now: day(2026, 10, 20), calendar: calendar)?.days == 12)
    }

    @Test func otherQuestionsGetOnlyTheDate() {
        #expect(DateFacts.daysUntil("what's the weather like", now: day(2026, 10, 20), calendar: calendar) == nil)
        #expect(DateFacts.lines(for: "what day is it", now: day(2026, 10, 20), calendar: calendar).count == 1)
    }

    @Test func aPlainAskCarriesThemFirst() {
        var request = AskRequest(question: "how many days until christmas?", screenshotJPEG: Data(), screenshotWidth: 640,
                                 screenshotHeight: 400, context: ScreenContext())
        request.now = Date()
        let text = Prompt.userText(for: request)
        #expect(text.hasPrefix("Today is "))
        #expect(text.contains("not counting today."))
        #expect(text.hasSuffix("The user said: how many days until christmas?"))
    }

    @Test func otherPromptsDontGetThem() {
        var request = AskRequest(question: "stash these", screenshotJPEG: Data(), screenshotWidth: 0,
                                 screenshotHeight: 0, context: ScreenContext())
        request.interpretOrder = true
        #expect(!Prompt.userText(for: request).contains("Today is"))
    }
}
