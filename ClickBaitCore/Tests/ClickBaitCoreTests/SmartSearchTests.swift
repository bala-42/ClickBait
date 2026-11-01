import Foundation
import Testing
@testable import ClickBaitCore

struct SmartSearchTests {
    @Test func knowsASearchQuestion() {
        #expect(SmartSearch.request(in: "find that note about the dentist") == .init(kind: .note, terms: ["dentist"], text: "dentist"))
        #expect(SmartSearch.request(in: "where's the march invoice pdf")?.kind == .file)  // a named kind of thing
        #expect(SmartSearch.request(in: "where's the wifi") == nil)
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

    @Test func theBrainsRelatedWordsHelpTheLeap() {
        let request = SmartSearch.Request(kind: .note, terms: ["dentist"], text: "dentist")
            .with(related: "Toothache, Drill, Cleaning, Dentist, Appointment")
        #expect(request.related == ["toothache", "drill", "cleaning", "appointment"])
        #expect(request.text == "dentist, toothache, drill, cleaning, appointment")
        let cleaning = SmartSearch.Item(id: "1", kind: .note, title: "Tuesday", place: "Notes", text: "cleaning on Tuesday at 3")
        let plumber = SmartSearch.Item(id: "2", kind: .note, title: "Plumber", place: "Notes", text: "comes Thursday")
        // Same meaning score (as nomic gave them): the shared word decides.
        #expect(SmartSearch.rank([(plumber, [0.6, 0.8]), (cleaning, [0.6, 0.8])], for: request, query: [0.6, 0.8]).first?.id == "1")
    }

    @Test func repliesWithLinksAndWhereThingsAre() {
        let request = SmartSearch.Request(kind: .file, terms: ["invoice"], text: "invoice")
        let pdf = SmartSearch.Item(id: "f", kind: .file, title: "invoice-march.pdf", place: "Downloads", text: "", file: "/Users/me/Downloads/invoice-march.pdf")
        #expect(SmartSearch.reply([pdf], for: request) == "Found it:\n• [invoice-march.pdf](file:///Users/me/Downloads/invoice-march.pdf) — Downloads")
        #expect(SmartSearch.reply([], for: request) == "I couldn't find anything about invoice on this Mac.")
    }

    @Test func knowsWhenThePictureIsOfTheUser() {
        #expect(SmartSearch.request(in: "find me an image where I'm holding a dog")?.wantsMe == true)
        #expect(SmartSearch.request(in: "find me an image where I'm holding a dog")?.terms == ["holding", "dog"])
        #expect(SmartSearch.request(in: "show me the picture of the airport")?.wantsMe == false)
        #expect(SmartSearch.request(in: "find a photo of me at the beach")?.wantsMe == true)
        #expect(SmartSearch.request(in: "find the note about me and the dentist")?.wantsMe == false)  // notes, not pictures
    }

    @Test func followUpsActOnTheResults() {
        #expect(SmartSearch.followUp(in: "open it", count: 3) == .open(0))
        #expect(SmartSearch.followUp(in: "open the second one", count: 3) == .open(1))
        #expect(SmartSearch.followUp(in: "yes, open that", count: 1) == .open(0))
        #expect(SmartSearch.followUp(in: "show the last one in Finder", count: 3) == .reveal(2))
        #expect(SmartSearch.followUp(in: "open number 3", count: 3) == .open(2))
        #expect(SmartSearch.followUp(in: "open Safari", count: 3) == nil)
        #expect(SmartSearch.followUp(in: "open the fifth one", count: 3) == nil)
        #expect(SmartSearch.followUp(in: "open it", count: 0) == nil)
    }

    @Test func saysWhyAndShowsDetails() {
        let request = SmartSearch.Request(kind: .image, terms: ["dog"], text: "dog")
        var picture = SmartSearch.Item(id: "p", kind: .image, title: "me_with_dog.png", place: "Downloads", text: "animal, dog",
                                       modified: Date(timeIntervalSince1970: 1_773_187_200), bytes: 460_000)
        #expect(SmartSearch.reason(for: picture, request: request, spotlight: false) == "Matches “dog” in the name")
        picture.title = "IMG_1852.HEIC"
        #expect(SmartSearch.reason(for: picture, request: request, spotlight: false) == "Matches “dog” in the picture")
        let calendar = Calendar(identifier: .gregorian)
        #expect(picture.details(now: Date(timeIntervalSince1970: 1_780_000_000), calendar: calendar) == "Downloads · 460 KB · Mar 11")
    }

    @Test func oneStrongMatchDoesntHideTheOtherGoodOnes() {
        let request = SmartSearch.Request(kind: .image, terms: ["dog"], text: "dog")
        let named = SmartSearch.Item(id: "a", kind: .image, title: "dog.png", place: "Downloads", text: "")
        let pictured = SmartSearch.Item(id: "b", kind: .image, title: "IMG_1.jpg", place: "Photos", text: "", caption: "A white dog on a sofa")
        let unrelated = SmartSearch.Item(id: "c", kind: .image, title: "chart.png", place: "Desktop", text: "chart")
        // "dog.png" is also a Spotlight hit, far ahead; the captioned dog picture still shows.
        let found = SmartSearch.rank([(named, [1, 0]), (pictured, [0.8, 0.6]), (unrelated, [0, 1])],
                                     for: request, query: [1, 0], boosted: ["a"])
        #expect(found.map(\.id) == ["a", "b"])
    }

    @Test func videosAreAKindAndShortPhrasesSearch() {
        let find = SmartSearch.request(in: "find shampoo videos")
        #expect(find?.kind == .video && find?.terms == ["shampoo"])
        #expect(SmartSearch.request(in: "shampoo videos")?.terms == ["shampoo"])
        #expect(SmartSearch.request(in: "beach photos")?.kind == .image)
        #expect(SmartSearch.request(in: "make a video about cats") == nil)  // not a search
    }

    @Test func openNowIsASearch() {
        let open = SmartSearch.request(in: "find the video I have open")
        #expect(open?.kind == .video && open?.openNow == true && open?.terms.isEmpty == true)
        let named = SmartSearch.request(in: "find the shampoo video that's playing")
        #expect(named?.openNow == true && named?.terms == ["shampoo"])
        #expect(SmartSearch.request(in: "find the shampoo videos")?.openNow == false)
        let none = SmartSearch.Request(kind: .video, terms: ["towel"], text: "towel")
        #expect(SmartSearch.headline([], for: none, waiting: 50, waitingWhy: "on battery").contains("50 pictures and videos aren't read yet"))
    }

    @Test func stems() {
        #expect(SmartSearch.stem("shampooing") == "shampoo")
        #expect(SmartSearch.stem("shoulders") == "shoulder")
        #expect(SmartSearch.stem("wearing") == "wear")
        #expect(SmartSearch.stem("hair") == "hair")
        #expect(SmartSearch.stem("towel") == "towel")
    }

    @Test func ownMeansThemselves() {
        let request = SmartSearch.request(in: "find me videos of a girl shampooing her own hair")!
        func item(_ caption: String) -> SmartSearch.Item {
            var item = SmartSearch.Item(id: caption, kind: .video, title: "v.mp4", place: "x", text: "", file: "/x/v.mp4")
            item.caption = caption
            return item
        }
        #expect(SmartSearch.selfMatch(request, item("A video of a person washing their long, dark hair with white foam in a room.")) > 0)
        #expect(SmartSearch.selfMatch(request, item("A video of a woman having her hair washed by a stylist at a salon.")) < 0)
        #expect(SmartSearch.selfMatch(request, item("A video of a mannequin head being washed.")) < 0)
        let plain = SmartSearch.request(in: "find shampoo videos")!
        #expect(SmartSearch.selfMatch(plain, item("A video of a woman having her hair washed by a stylist.")) == 0)
    }
}
