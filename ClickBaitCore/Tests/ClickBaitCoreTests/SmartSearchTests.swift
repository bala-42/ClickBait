import Testing
@testable import ClickBaitCore

struct SmartSearchTests {
    @Test func knowsASearchQuestion() {
        #expect(SmartSearch.request(in: "find that note about the dentist") == .init(kind: .note, terms: ["dentist"], text: "dentist"))
        #expect(SmartSearch.request(in: "where's the march invoice pdf")?.kind == nil)  // "where's the" isn't a search phrase
        #expect(SmartSearch.request(in: "find the march invoice pdf")?.kind == .file)
        #expect(SmartSearch.request(in: "show me the picture of the airport")?.terms == ["airport"])
        #expect(SmartSearch.request(in: "show me the picture of the airport")?.kind == .image)
        #expect(SmartSearch.request(in: "do I have a reminder about the car?")?.kind == .reminder)
        #expect(SmartSearch.request(in: "what did I write about the plumber")?.kind == .note)
        #expect(SmartSearch.request(in: "search for tax forms")?.terms == ["tax", "forms"])
    }

    @Test func leavesPointingAndOtherQuestionsAlone() {
        #expect(SmartSearch.request(in: "where's the share button?") == nil)
        #expect(SmartSearch.request(in: "find the settings menu") == nil)
        #expect(SmartSearch.request(in: "what's the weather like") == nil)
        #expect(SmartSearch.request(in: "find") == nil)
    }

    @Test func ranksByMeaningThenWords() {
        let request = SmartSearch.Request(kind: .note, terms: ["dentist"], text: "dentist")
        let cleaning = SmartSearch.Item(id: "1", kind: .note, title: "Tuesday", place: "Notes", text: "cleaning on Tuesday at 3")
        let shopping = SmartSearch.Item(id: "2", kind: .note, title: "Shopping", place: "Notes", text: "milk, eggs")
        let found = SmartSearch.rank([(cleaning, [0.9, 0.1]), (shopping, [0.1, 0.9])], for: request, query: [1, 0])
        #expect(found.map(\.id) == ["1"])
        #expect(SmartSearch.cosine([1, 0], [1, 0]) == 1)
        // nomic's "unrelated" band (≈ 0.47) doesn't get through on its own.
        let weak = SmartSearch.rank([(shopping, [0.47, 0.88])], for: request, query: [1, 0])
        #expect(weak.isEmpty)
    }

    @Test func repliesWithLinksAndWhereThingsAre() {
        let request = SmartSearch.Request(kind: .file, terms: ["invoice"], text: "invoice")
        let pdf = SmartSearch.Item(id: "f", kind: .file, title: "invoice-march.pdf", place: "Downloads", text: "", file: "/Users/me/Downloads/invoice-march.pdf")
        #expect(SmartSearch.reply([pdf], for: request) == "Found it:\n• [invoice-march.pdf](file:///Users/me/Downloads/invoice-march.pdf) — Downloads")
        #expect(SmartSearch.reply([], for: request) == "I couldn't find anything about invoice on this Mac.")
    }
}
