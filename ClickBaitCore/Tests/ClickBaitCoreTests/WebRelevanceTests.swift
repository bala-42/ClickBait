import Testing
@testable import ClickBaitCore

struct WebRelevanceTests {
    @Test func dropsOffTopicArticles() {
        let query = "passport renewal fee"
        #expect(!WebRelevance.isRelevant(title: "Gab (social network)", text: "Gab is an American social network…", query: query))
        #expect(!WebRelevance.isRelevant(title: "List of scams", text: "An advance-fee scam asks for a fee…", query: query))
        #expect(WebRelevance.isRelevant(title: "Passport", text: "Renewal fees vary by country.", query: query))
    }

    @Test func longQueriesNeedMostOfTheirWords() {
        let query = "swift async let structured concurrency task group"
        #expect(WebRelevance.isRelevant(title: "Swift concurrency", text: "async let and task groups are structured", query: query))
        #expect(!WebRelevance.isRelevant(title: "Swift (bird)", text: "A swift is a fast bird.", query: query))
    }

    @Test func fillerAloneKeepsEverything() {
        #expect(WebRelevance.isRelevant(title: "x", text: "y", query: "how to"))
    }
}
