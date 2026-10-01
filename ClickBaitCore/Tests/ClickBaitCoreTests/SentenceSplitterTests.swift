import Testing
@testable import ClickBaitCore

struct SentenceSplitterTests {
    private func split(_ chunks: [String]) -> [String] {
        var splitter = SentenceSplitter()
        var out = chunks.flatMap { splitter.feed($0) }
        if let rest = splitter.flush() { out.append(rest) }
        return out
    }

    @Test func splitsOnTerminatorsFollowedBySpace() {
        #expect(split(["Click Share. Then choose Copy Link! Done?"]) == ["Click Share.", "Then choose Copy Link!", "Done?"])
    }

    @Test func emitsTheFirstSentenceAsSoonAsTheNextBegins() {
        var splitter = SentenceSplitter()
        #expect(splitter.feed("Click the Share") == [])
        #expect(splitter.feed(" button.") == [])  // can't tell yet: "button.5"?
        #expect(splitter.feed(" Then") == ["Click the Share button."])
        #expect(splitter.flush() == "Then")
    }

    @Test func keepsAbbreviationsAndNumbersTogether() {
        #expect(split(["Use a shortcut, e.g. ⌘C, to copy. It costs 3.5 dollars."]) == [
            "Use a shortcut, e.g. ⌘C, to copy.", "It costs 3.5 dollars.",
        ])
        #expect(split(["Ask Dr. Lee about version 2.1 first. Then restart."]) == [
            "Ask Dr. Lee about version 2.1 first.", "Then restart.",
        ])
        #expect(split(["Written by J. Smith. Read it."]) == ["Written by J. Smith.", "Read it."])
    }

    @Test func handlesEllipsesRunsAndClosingQuotes() {
        #expect(split(["Wait… then click. Really?! Yes. Click “Save.” Now."]) == [
            "Wait…", "then click.", "Really?!", "Yes.", "Click “Save.”", "Now.",
        ])
    }

    @Test func toleratesNewlines() {
        #expect(split(["First line.\nSecond line."]) == ["First line.", "Second line."])
    }

    @Test func emptyAndWhitespaceOnly() {
        #expect(split([""]) == [])
        #expect(split(["   "]) == [])
    }

    @Test func characterByCharacterGivesTheSameResult() {
        let text = "Open Settings. Click e.g. General, then About. Done."
        #expect(split(text.map(String.init)) == split([text]))
    }
}
