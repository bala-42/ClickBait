import Foundation
import Testing
@testable import ClickBaitCore

struct VisionMemoryTests {
    @Test func secretLinesAreNotKept() {
        let guarded = VisionMemory.guardText("Bank login\npassword: hunter22\nCard 4111 1111 1111 1111\nThanks!")
        #expect(guarded.sensitive)
        #expect(!guarded.kept.contains("hunter22") && !guarded.kept.contains("4111"))
        #expect(guarded.kept.contains("Thanks!"))
        #expect(!VisionMemory.guardText("Gate B12 boarding 14:05").sensitive)
    }

    @Test func documentsGetTheirOwnPrompt() {
        #expect(VisionMemory.isDocumentLike(labels: "document, chart", name: "q3.png"))
        #expect(VisionMemory.isDocumentLike(labels: "", name: "Screenshot 2026-11-01 at 10.02.png"))
        #expect(!VisionMemory.isDocumentLike(labels: "animal, dog, grass", name: "IMG_2041.jpg"))
        #expect(VisionMemory.captionPrompt(documentLike: true).contains("chart, slide"))
    }

    @Test func excludedFoldersAndTheirInsides() {
        let excluded = ["/Users/me/Documents/Taxes"]
        #expect(VisionMemory.isExcluded("/Users/me/Documents/Taxes/2025/w2.png", excluded: excluded))
        #expect(!VisionMemory.isExcluded("/Users/me/Documents/Taxes-ideas.png", excluded: excluded))
    }

    @Test func copiesBecomeOneResult() {
        func shot(_ id: String, _ key: String?) -> SmartSearch.Item {
            .init(id: id, kind: .image, title: id, place: "Desktop", text: "", file: "/d/\(id)")
                .with { $0.contentKey = key }
        }
        let collapsed = VisionMemory.collapseCopies([shot("a", "k1"), shot("b", "k2"), shot("c", "k1"), shot("d", nil), shot("e", "k1")])
        #expect(collapsed.map(\.id) == ["a", "b", "d"])
        #expect(collapsed[0].copies == ["/d/c", "/d/e"])
        #expect(collapsed[0].details().hasSuffix("3 copies"))
    }

    @Test func halfPrecisionKeepsTheVector() {
        let vector: [Float] = [0.0123456, -0.5, 0.25, 0.9999]
        let back = VisionMemory.unpack(VisionMemory.pack(vector))
        #expect(VisionMemory.pack(vector).count == 8)
        #expect(zip(vector, back).allSatisfy { abs($0 - $1) < 0.001 })
    }
}

private extension SmartSearch.Item {
    func with(_ change: (inout Self) -> Void) -> Self { var copy = self; change(&copy); return copy }
}
