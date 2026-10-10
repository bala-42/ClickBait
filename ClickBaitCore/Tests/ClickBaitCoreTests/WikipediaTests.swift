import Foundation
import Testing
@testable import ClickBaitCore

struct StreamingSubjectTests {
    @Test func readsTheSubjectOnceItsStringCloses() {
        #expect(StreamingSubject.subject(in: #"{"subject": "Rotator cu"#) == nil)
        #expect(StreamingSubject.subject(in: #"{"subject": "Rotator cuff", "spe"#) == "Rotator cuff")
        #expect(StreamingSubject.subject(in: "{\n  \"subject\" :\"Solar System\"") == "Solar System")
    }

    @Test func noneAndNonsenseStartNoLookup() {
        #expect(StreamingSubject.subject(in: #"{"subject": "none", "speech": "Hi"}"#) == nil)
        #expect(StreamingSubject.subject(in: #"{"subject": "  ", "speech": "Hi"}"#) == nil)
        #expect(StreamingSubject.subject(in: #"{"speech": "A planet."}"#) == nil)
        let rambling = #"{"subject": "a picture of some planets going round the sun in a line", "#
        #expect(StreamingSubject.subject(in: rambling) == nil)
    }

    @Test func keepsEscapedQuotes() {
        #expect(StreamingSubject.subject(in: #"{"subject": "The \"Scream\"", "#) == #"The "Scream""#)
    }
}

struct WikipediaClientTests {
    @Test func searchSendsOnlyTheSubject() throws {
        let url = try #require(WikipediaClient.searchURL(for: "Rotator cuff"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(url.host == "en.wikipedia.org")
        #expect(items.first(where: { $0.name == "srsearch" })?.value == "Rotator cuff")
        #expect(WikipediaClient.searchURL(for: "  ") == nil)
    }

    @Test func summaryURLEscapesTheTitle() {
        #expect(WikipediaClient.summaryURL(forTitle: "Mona Lisa")?.absoluteString
                == "https://en.wikipedia.org/api/rest_v1/page/summary/Mona_Lisa")
        #expect(WikipediaClient.summaryURL(forTitle: "AC/DC")?.absoluteString.hasSuffix("AC%2FDC") == true)
    }

    @Test func readsTheTopSearchHit() {
        let data = Data(#"{"query":{"search":[{"ns":0,"title":"Supraspinatus muscle","pageid":1}]}}"#.utf8)
        #expect(WikipediaClient.topTitle(inSearch: data) == "Supraspinatus muscle")
        #expect(WikipediaClient.topTitle(inSearch: Data(#"{"query":{"search":[]}}"#.utf8)) == nil)
    }

    @Test func readsASummaryWithItsLink() throws {
        let data = Data("""
            {"type":"standard","title":"Rotator cuff","extract":"The rotator cuff is a group of four muscles.",
             "content_urls":{"desktop":{"page":"https://en.wikipedia.org/wiki/Rotator_cuff"}}}
            """.utf8)
        let reference = try #require(WikipediaClient.reference(inSummary: data))
        #expect(reference.title == "Rotator cuff")
        #expect(reference.extract == "The rotator cuff is a group of four muscles.")
        #expect(reference.credit == "Source: [Wikipedia — Rotator cuff](https://en.wikipedia.org/wiki/Rotator_cuff)")
    }

    @Test func disambiguationPagesAreSkipped() {
        let data = Data(#"{"type":"disambiguation","title":"Mercury","extract":"Mercury may refer to:"}"#.utf8)
        #expect(WikipediaClient.reference(inSummary: data) == nil)
    }

    @Test func longExtractsEndAtASentence() {
        let long = String(repeating: "Jupiter is big. ", count: 200)
        let trimmed = WikipediaClient.trimmed(long)
        #expect(trimmed.count <= WikipediaClient.maxExtractCharacters)
        #expect(trimmed.hasSuffix("."))
    }

    @Test func theMarksRequestCarriesTheReference() throws {
        var request = AskRequest(question: "The planets of the Solar System.", screenshotJPEG: Data(),
                                 screenshotWidth: 960, screenshotHeight: 540, context: ScreenContext())
        request.markNames = ["Mars", "Venus"]
        request.markCount = 2
        #expect(!Prompt.userText(for: request).contains("Wikipedia"))
        request.reference = WikiReference(title: "Solar System", extract: "Mars is reddish; Venus is pale yellow.",
                                          url: try #require(URL(string: "https://en.wikipedia.org/wiki/Solar_System")))
        let text = Prompt.userText(for: request)
        #expect(text.contains("Background from Wikipedia (\"Solar System\")"))
        #expect(text.contains("Mars is reddish"))
    }

    @Test func aSubjectReplyWithNullCodeHasNoCode() {
        let reply = #"{"subject": "Solar System", "speech": "A model of the Solar System.", "code": "null", "language": "none"}"#
        let parsed = ResponseParser.parse(reply, imageWidth: 1280, imageHeight: 800)
        #expect(parsed.response.speech == "A model of the Solar System.")
        #expect(parsed.response.code == nil)
        #expect(parsed.response.language == nil)
    }

    @Test func onlyLookupsAskForTheSubject() throws {
        var request = AskRequest(question: "", screenshotJPEG: Data(), screenshotWidth: 1280, screenshotHeight: 800,
                                 context: ScreenContext(), snip: .circled)
        #expect(!Prompt.userText(for: request).contains("\"subject\""))
        #expect(OllamaProvider.schema(for: request) == nil)
        request.askSubject = true
        #expect(Prompt.userText(for: request).contains("Also give \"subject\", first in the JSON"))
        let schema = try #require(OllamaProvider.schema(for: request))
        #expect((schema["required"] as? [String]) == ["subject"])
    }
}

/// Real requests to Wikipedia: `CLICKBAIT_LIVE_WIKIPEDIA=1 swift test --package-path ClickBaitCore --filter LiveWikipedia`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CLICKBAIT_LIVE_WIKIPEDIA"] != nil))
struct LiveWikipediaTests {
    @Test(arguments: [("Rotator cuff", "Rotator cuff"), ("Solar System", "Solar System"), ("supraspinatus", "Supraspinatus muscle")])
    func findsTheArticle(subject: String, title: String) async throws {
        let start = ContinuousClock.now
        let reference = try #require(await WikipediaClient().reference(for: subject))
        print("\(subject) → \(reference.title): \(reference.extract.count) characters in \(ContinuousClock.now - start)")
        #expect(reference.title == title)
        #expect(reference.extract.count <= WikipediaClient.maxExtractCharacters)
    }
}
