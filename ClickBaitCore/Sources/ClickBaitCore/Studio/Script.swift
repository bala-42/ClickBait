import Foundation

/// Studio's teleprompter script (user's ask, 2026-11-01): the text read under the camera,
/// split into cues to jump between. Pure.
///
///     Script(text: "# Intro\nHi, I'm Bala.\n\n# Demo\nHere's the notch.").cues.map(\.title)
///     // ["Intro", "Demo"]
public struct Script: Equatable, Sendable {
    public struct Cue: Equatable, Sendable, Identifiable {
        public var id: Int { start }
        /// What the dropdown shows.
        public let title: String
        /// Where the cue starts in `text` (a character offset), for jumping there.
        public let start: Int
    }

    public let text: String
    public let cues: [Cue]

    public init(text: String) {
        self.text = text
        self.cues = Self.cues(in: text)
    }

    /// Cues from the script's own marks: Markdown headings ("# Intro"), short lines ending in
    /// a colon ("Demo:"), short all-capital lines ("INTRO"), and the text after a divider
    /// ("---"). With no marks, each paragraph is a cue named by its first words.
    static func cues(in text: String) -> [Cue] {
        var marked: [Cue] = []
        var paragraphs: [Cue] = []
        var offset = 0
        var afterDivider = false
        var newParagraph = true
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(line)
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            defer { offset += raw.count + 1 }
            if trimmed.isEmpty { newParagraph = true; continue }
            if trimmed.allSatisfy({ "-*_=".contains($0) }), trimmed.count >= 3 { afterDivider = true; newParagraph = true; continue }
            if let heading = heading(trimmed) {
                marked.append(Cue(title: heading, start: offset))
                afterDivider = false
                newParagraph = false
                continue
            }
            if afterDivider {
                marked.append(Cue(title: firstWords(trimmed), start: offset))
                afterDivider = false
            }
            if newParagraph { paragraphs.append(Cue(title: firstWords(trimmed), start: offset)) }
            newParagraph = false
        }
        return marked.isEmpty ? paragraphs : marked
    }

    /// A line that names a section, or nil.
    static func heading(_ line: String) -> String? {
        if line.hasPrefix("#") {
            let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : title
        }
        let words = line.split(separator: " ")
        if line.hasSuffix(":"), words.count <= 6 { return String(line.dropLast()).trimmingCharacters(in: .whitespaces) }
        let letters = line.filter(\.isLetter)
        if letters.count >= 3, words.count <= 6, letters == letters.uppercased(), !line.hasSuffix(".") { return line.capitalized }
        return nil
    }

    static func firstWords(_ line: String) -> String {
        let words = line.split(separator: " ").prefix(6).joined(separator: " ")
        return words.count < line.count ? words + "…" : words
    }

    /// The cue `offset` is in (the last one starting at or before it).
    public func cue(at offset: Int) -> Cue? {
        cues.last { $0.start <= offset } ?? cues.first
    }

    /// The line (0-based) a character offset is on: `readable` keeps every line, so the
    /// prompter's lines and the cues meet by line, not by character.
    public func line(of offset: Int) -> Int {
        text.prefix(max(0, offset)).reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
    }

    /// The cue being read when `line` is at the top.
    public func cue(atLine line: Int) -> Cue? {
        cues.last { self.line(of: $0.start) <= line } ?? cues.first
    }

    /// The text to show: the script without heading marks and dividers (headings stay as lines).
    public var readable: String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.count >= 3, trimmed.allSatisfy({ "-*_=".contains($0) }) { return "" }
            if trimmed.hasPrefix("#") { return trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) }
            return String(line)
        }.joined(separator: "\n")
    }
}
