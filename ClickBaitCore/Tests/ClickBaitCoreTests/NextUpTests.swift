import Foundation
import Testing
@testable import ClickBaitCore

struct NextUpTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func dueOnlyInTheLastFiveMinutesOnce() {
        let soon = NextUp.Event(id: "a", title: "Standup", start: now + 240, places: [])
        let later = NextUp.Event(id: "b", title: "Review", start: now + 900, places: [])
        #expect(NextUp.due([later, soon], now: now, told: []) == soon)
        #expect(NextUp.due([later, soon], now: now, told: ["a"]) == nil)
        #expect(NextUp.due([later], now: now, told: []) == nil)
        #expect(NextUp.due([NextUp.Event(id: "c", title: "Gone", start: now - 300, places: [])], now: now, told: []) == nil)
    }

    @Test func findsCallLinks() {
        #expect(NextUp.link(in: ["Room 4", "Join: https://us02web.zoom.us/j/8123456789?pwd=abc thanks"])?.absoluteString == "https://us02web.zoom.us/j/8123456789?pwd=abc")
        #expect(NextUp.link(in: ["https://meet.google.com/abc-defg-hij"])?.host == "meet.google.com")
        #expect(NextUp.link(in: ["<https://teams.microsoft.com/l/meetup-join/19%3ameeting_x>"])?.host == "teams.microsoft.com")
        #expect(NextUp.link(in: ["https://example.com/agenda"]) == nil)
    }
}
