import Foundation
import Testing
@testable import ClickBaitCore

struct ReminderTextTests {
    @Test func noDaySaidMeansAsk() {
        let parsed = ReminderText.parse("Water my plants")
        #expect(parsed.title == "water my plants")
        #expect(parsed.day == nil)
    }

    @Test func titlesAreSmallLetters() {
        #expect(ReminderText.parse("Call Mum about Paris").title == "call mum about paris")
    }

    @Test func webAddressesKeepTheirCase() {
        let title = "Read https://example.com/Docs/Guide"
        #expect(ReminderText.parse(title).title == title)
    }

    @Test(arguments: [
        ("Water my plants tomorrow.", ReminderDay.inDays(1)),
        ("water my plants by tomorrow", .inDays(1)),
        ("Tomorrow, water my plants", .inDays(1)),
        ("water my plants tonight", .inDays(0)),
        ("water my plants on Friday", .weekday(6)),
        ("water my plants by next Monday", .weekday(2)),
        ("water my plants next week", .inDays(7)),
        ("water my plants in 3 days", .inDays(3)),
        ("water my plants on the 12th", .dayOfMonth(12)),
        ("water my plants the day after tomorrow", .inDays(2)),
    ])
    func daysAreTakenOutOfTheTitle(_ text: String, _ day: ReminderDay) {
        let parsed = ReminderText.parse(text)
        #expect(parsed.title == "water my plants")
        #expect(parsed.day == day)
    }

    @Test(arguments: [ReminderDay.inDays(0), .inDays(1), .inDays(5), .weekday(6), .weekday(1), .dayOfMonth(1),
                      .dayOfMonth(2), .dayOfMonth(13), .dayOfMonth(22)])
    func answeredDaysRoundTrip(_ day: ReminderDay) {
        let parsed = ReminderText.parse("water my plants " + day.phrase)
        #expect(parsed.title == "water my plants")
        #expect(parsed.day == day)
    }

    @Test func dayWordsInsideTheTitleStay() {
        let parsed = ReminderText.parse("ask about tomorrow's meeting agenda")
        #expect(parsed.title == "ask about tomorrow's meeting agenda")
        #expect(parsed.day == nil)
    }

    @Test func aNumberAtTheEndIsNotADay() {
        // "call 911" isn't the 911th; "buy 2" isn't the 2nd.
        #expect(ReminderText.parse("buy eggs 2").day == nil)
        #expect(ReminderText.parse("call 911").day == nil)
        #expect(ReminderText.parse("pay rent on 1").day == .dayOfMonth(1))
        #expect(ReminderText.parse("pay rent 1st").day == .dayOfMonth(1))
    }

    @Test(arguments: [
        ("Friday.", ReminderDay.weekday(6)),
        ("Tomorrow please", .inDays(1)),
        ("today", .inDays(0)),
        ("On the 3rd.", .dayOfMonth(3)),
        ("in two weeks", .inDays(14)),
        ("make it next Tuesday", .weekday(3)),
        ("next week", .inDays(7)),
    ])
    func spokenAnswers(_ answer: String, _ day: ReminderDay) {
        #expect(ReminderDay.parse(answer) == day)
    }

    @Test(arguments: ["yes", "cancel", "water my plants", "what's the weather"])
    func notADay(_ answer: String) {
        #expect(ReminderDay.parse(answer) == nil)
    }

    // Thursday 1 October 2026, 15:00.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 15))! }

    private func due(_ day: ReminderDay) -> String {
        let parts = day.dueDate(from: now, calendar: calendar)
        return "\(parts.year!)-\(parts.month!)-\(parts.day!)"
    }

    @Test func resolvesToAllDayDates() {
        #expect(due(.inDays(0)) == "2026-10-1")
        #expect(due(.inDays(1)) == "2026-10-2")
        #expect(due(.weekday(6)) == "2026-10-2")   // Friday: the coming one
        #expect(due(.weekday(5)) == "2026-10-8")   // Thursday said on a Thursday: next week
        #expect(due(.weekday(4)) == "2026-10-7")   // Wednesday: the coming one
        #expect(due(.dayOfMonth(12)) == "2026-10-12")
        #expect(due(.dayOfMonth(1)) == "2026-10-1")   // today still counts
        #expect(due(.dayOfMonth(31)) == "2026-10-31")
        #expect(day(.dayOfMonth(31), from: 2026, 11, 5) == "2026-12-31")  // November has no 31st
    }

    @Test func dueDatesHaveNoTime() {
        let parts = ReminderDay.inDays(1).dueDate(from: now, calendar: calendar)
        #expect(parts.hour == nil && parts.minute == nil)
    }

    private func day(_ day: ReminderDay, from year: Int, _ month: Int, _ date: Int) -> String {
        let start = calendar.date(from: DateComponents(year: year, month: month, day: date, hour: 9))!
        let parts = day.dueDate(from: start, calendar: calendar)
        return "\(parts.year!)-\(parts.month!)-\(parts.day!)"
    }
}
