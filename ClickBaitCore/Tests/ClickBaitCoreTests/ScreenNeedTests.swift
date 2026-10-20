import Foundation
import Testing
@testable import ClickBaitCore

/// Which questions go to the model without the screenshot (~1–2 s instead of ~8.5 s), and
/// which date questions ClickBait answers itself.
struct ScreenNeedTests {
    @Test func worldQuestionsGoWithout() {
        for question in ["Why is the sky blue?", "how many days until christmas", "What's the capital of Peru?",
                         "who wrote Hamlet", "Is a tomato a fruit?", "convert 5 miles to km",
                         "explain quantum entanglement simply", "how far is the moon"] {
            #expect(ScreenNeed.isAboutTheWorld(question), "\(question)")
        }
    }

    @Test func screenQuestionsKeepIt() {
        for question in ["what's this?", "where's the share button?", "why is this greyed out", "what does that icon do",
                         "how do I export this", "how do i change my wallpaper", "is my code right", "what's on the screen",
                         "explain the chart", "who sent this email", "open safari", "show me the settings",
                         "summarize", "can you read the error"] {
            #expect(!ScreenNeed.isAboutTheWorld(question), "\(question)")
        }
    }

    @Test func selectionsSnipsAndFollowUpsKeepIt() {
        #expect(!ScreenNeed.isAboutTheWorld("why is the sky blue", selectedText: "Rayleigh scattering"))
        #expect(!ScreenNeed.isAboutTheWorld("why is the sky blue", snipped: true))
        #expect(!ScreenNeed.isAboutTheWorld("why is the sky blue", followUp: true))
    }

    @Test func aTextOnlyAskSaysSo() {
        var request = AskRequest(question: "why is the sky blue", screenshotJPEG: Data(), screenshotWidth: 1280,
                                 screenshotHeight: 831, context: ScreenContext())
        request.now = Date()
        #expect(Prompt.userText(for: request).contains("No screenshot this time: the question isn't about the screen."))
    }
}

struct InstantDateAnswerTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
        return calendar
    }
    private var oct20: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 11))! }

    @Test func daysUntil() {
        #expect(DateFacts.instantAnswer("How many days until Christmas?", now: oct20, calendar: calendar) == "66 days until Christmas!")
        #expect(DateFacts.instantAnswer("days till halloween", now: oct20, calendar: calendar) == "11 days until Halloween!")
        #expect(DateFacts.instantAnswer("how many days until october 21", now: oct20, calendar: calendar) == "1 day until October 21!")
    }

    @Test func todaysDate() {
        #expect(DateFacts.instantAnswer("What's the date?", now: oct20, calendar: calendar) == "It's Tuesday, 20 October.")
        #expect(DateFacts.instantAnswer("what day is it today", now: oct20, calendar: calendar) == "It's Tuesday, 20 October.")
    }

    @Test func notForOtherQuestions() {
        #expect(DateFacts.instantAnswer("plan a trip 3 days before christmas in japan please", now: oct20, calendar: calendar) == nil)
        #expect(DateFacts.instantAnswer("what is today's meeting about", now: oct20, calendar: calendar) == nil)
        #expect(DateFacts.instantAnswer("why is the sky blue", now: oct20, calendar: calendar) == nil)
    }
}
