import Testing
@testable import ClickBaitCore

struct NotchCheerTests {
    @Test func lowercaseAndShort() {
        for line in NotchCheer.lines {
            #expect(line == line.lowercased(), "\(line)")
            #expect(line.count <= 30, "\(line)")  // user's limit, kaomoji included
            // Combining accents (•̀ •́) render broken in the header's semibold type.
            #expect(!line.unicodeScalars.contains { $0.properties.canonicalCombiningClass != .notReordered }, "\(line)")
            // Kaomoji only, never pictorial emoji: no symbol that can draw as one, but ♥ and ♨,
            // which the user is happy with (2026-10-23).
            #expect(!line.unicodeScalars.contains { $0.value > 0x7F && $0.properties.isEmoji && !"♥♨".unicodeScalars.contains($0) }, "\(line)")
        }
        #expect(Set(NotchCheer.lines).count == NotchCheer.lines.count)
    }

    @Test func neverTheSameTwice() {
        var random = SystemRandomNumberGenerator()
        for line in NotchCheer.lines { #expect(NotchCheer.next(after: line, using: &random) != line) }
    }
}
