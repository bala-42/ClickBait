import Foundation
import Testing
@testable import ClickBaitCore

struct GreetingTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()

    func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func firstWakeOfTheDayGreets() {
        #expect(Greeting.shouldGreet(now: date(20, 8), awaySince: date(19, 23), lastGreeted: date(19, 8), calendar: calendar))
    }

    @Test func secondWakeTheSameDayDoesNot() {
        #expect(!Greeting.shouldGreet(now: date(20, 11), awaySince: date(20, 10), lastGreeted: date(20, 8), calendar: calendar))
    }

    @Test func longAwayGreetsAgainTheSameDay() {
        #expect(Greeting.shouldGreet(now: date(20, 15), awaySince: date(20, 10, 30), lastGreeted: date(20, 8), calendar: calendar))
    }

    @Test func shortLockAfterMidnightDoesNot() {
        #expect(!Greeting.shouldGreet(now: date(21, 0, 5), awaySince: date(21, 0, 2), lastGreeted: date(20, 8), calendar: calendar))
    }

    @Test func launchGreetsOncePerDay() {
        #expect(Greeting.shouldGreet(now: date(20, 9), awaySince: nil, lastGreeted: nil, calendar: calendar))
        #expect(!Greeting.shouldGreet(now: date(20, 9), awaySince: nil, lastGreeted: date(20, 8), calendar: calendar))
    }

    @Test func periods() {
        #expect(Greeting.Period(hour: 5) == .morning)
        #expect(Greeting.Period(hour: 12) == .afternoon)
        #expect(Greeting.Period(hour: 21) == .evening)
        #expect(Greeting.Period(hour: 2) == .lateNight)
    }

    @Test func avoidsRecentLines() {
        let count = Greeting.lines[.morning]!.count
        let recent = Array(0..<(count - 1))
        let picked = Greeting.line(at: date(20, 8), recent: recent, calendar: calendar, random: { _ in 0 })
        #expect(picked.index == count - 1)
    }

    @Test func allRecentStillPicks() {
        let count = Greeting.lines[.morning]!.count
        let picked = Greeting.line(at: date(20, 8), recent: Array(0..<count), calendar: calendar, random: { _ in 2 })
        #expect(picked.index == 2)
    }

    @Test func linesAreShortWithAKaomoji() {
        for line in Greeting.lines.values.joined() {
            #expect(line.count <= 45)
            #expect(line.contains("("))
            // All small letters, kaomoji only (user's rule, 2026-10-23): no capitals, no emoji,
            // and no combining accents (•̀ •́ render broken in the pill's type).
            #expect(line == line.lowercased(), "\(line)")
            // Kaomoji only, never pictorial emoji: no symbol that can draw as one, but ♥ and ♨,
            // which the user is happy with (2026-10-23).
            #expect(!line.unicodeScalars.contains { $0.value > 0x7F && $0.properties.isEmoji && !"♥♨".unicodeScalars.contains($0) }, "\(line)")
            #expect(!line.unicodeScalars.contains { $0.properties.canonicalCombiningClass != .notReordered }, "\(line)")
        }
    }

    @Test func timingStaysShort() {
        let short = Greeting.timing(for: "hi (•‿•)")
        #expect(short.hold == 1.5)
        let long = Greeting.timing(for: String(repeating: "a", count: 45))
        #expect(long.hold <= 2.5)
        #expect(long.typing + long.hold < 4)
    }
}
