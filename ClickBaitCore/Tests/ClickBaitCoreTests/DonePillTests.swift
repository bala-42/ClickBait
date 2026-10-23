import Testing
@testable import ClickBaitCore

struct DonePillTests {
    @Test func linesAreShortAndLowercase() {
        for (_, lines) in DonePill.lines {
            #expect(lines.count >= 3)
            for line in lines {
                #expect(line.count <= 32, "\(line)")
                #expect(line == line.lowercased(), "\(line)")
                // Kaomoji only, never pictorial emoji: no symbol that can draw as one, but ♥ and ♨,
                // which the user is happy with (2026-10-23).
                #expect(!line.unicodeScalars.contains { $0.value > 0x7F && $0.properties.isEmoji && !"♥♨".unicodeScalars.contains($0) }, "\(line)")
            }
        }
    }

    @Test func fitsTheTaskItCameFrom() {
        #expect(DonePill.task(kind: .snip, question: "x", answer: "y") == .snip)
        #expect(DonePill.task(kind: .walkthrough, question: "x", answer: "y") == .walkthrough)
        #expect(DonePill.task(kind: .answer, question: "write a palindrome check", answer: "Here.\n```python\nx\n```") == .code)
        #expect(DonePill.task(kind: .answer, question: "Why does this crash?", answer: "Because…") == .why)
        #expect(DonePill.task(kind: .answer, question: "so how do I merge these", answer: "Like…") == .how)
        #expect(DonePill.task(kind: .answer, question: "what's on my screen", answer: "A chat.") == .answer)
    }

    @Test func neverTheSameTwiceRunning() {
        var random = SystemRandomNumberGenerator()
        for line in DonePill.lines[.answer]! {
            #expect(DonePill.line(for: .answer, after: line, using: &random) != line)
        }
    }
}
