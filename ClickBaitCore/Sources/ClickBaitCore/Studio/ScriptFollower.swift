import Foundation

/// Where in the script the speaker is, from what speech recognition heard (user's ask,
/// 2026-11-01: a prompter that runs at your pace). The last few heard words are matched against
/// the script's words just behind and ahead of where reading was, forgiving of ad-libs,
/// skipped words and mishearings; it only moves on a confident match, so silence or talking
/// off-script leaves it where it is. Pure.
public struct ScriptFollower: Sendable {
    public struct Word: Equatable, Sendable {
        public let text: String
        /// The prompter line it's on (lines of `Script.readable`).
        public let line: Int
    }

    public struct Place: Equatable, Sendable {
        /// The last word read (index into `words`).
        public let word: Int
        public let line: Int
        /// How far through its line (0…1), for scrolling smoothly within a long line.
        public let fraction: Double
    }

    public let words: [Word]
    /// The last confident place; nil before the first match.
    public private(set) var place: Place?

    /// How many heard words are matched at once, and how far back and ahead to look.
    static let window = 6, lookBehind = 6, lookAhead = 40

    public init(readable: String) {
        var words: [Word] = []
        for (line, text) in readable.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            words += Self.normalized(String(text)).map { Word(text: $0, line: line) }
        }
        self.words = words
    }

    /// "Hi, I'm Bala!" → ["hi", "im", "bala"].
    public static func normalized(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .map { $0.replacingOccurrences(of: "'", with: "") }
            .filter { !$0.isEmpty }
    }

    /// Jumped (a cue picked, or scrolled by hand): reading resumes from the start of `line`.
    public mutating func resume(atLine line: Int) {
        guard let index = words.firstIndex(where: { $0.line >= line }) else { return }
        place = Self.place(of: index - 1 < 0 ? 0 : index - 1, in: words)
        if index == 0 { place = nil }
    }

    /// Feeds what's been heard (the recent transcript); the new place when it moved.
    @discardableResult
    public mutating func hear(_ transcript: String) -> Place? {
        let heard = Array(Self.normalized(transcript).suffix(Self.window))
        guard !heard.isEmpty, !words.isEmpty else { return nil }
        let from = place?.word ?? -1
        let low = max(0, from - Self.lookBehind), high = min(words.count - 1, from + Self.lookAhead)
        guard low <= high else { return nil }
        var best: (end: Int, score: Double)?
        for end in low...high {
            let score = Self.score(heard, endingAt: end, in: words)
            // A tie goes to the nearest place ahead of where reading was.
            let distance = Double(abs(end - (from + 1))) * 0.01
            if score - distance > (best.map { $0.score - Double(abs($0.end - (from + 1))) * 0.01 } ?? 0) {
                best = (end, score)
            }
        }
        // Two words matching in order is a confident match; one only right where reading is.
        guard let best, best.score >= 2 || (best.score >= 1 && best.end - from >= 0 && best.end - from <= 2 && heard.count <= 2)
        else { return nil }
        guard best.end != place?.word else { return nil }
        place = Self.place(of: best.end, in: words)
        return place
    }

    /// The heard words against the script's words ending at `end`, newest last: each match
    /// counts 1 (close spellings 0.8), and a little slack for one word heard or skipped.
    static func score(_ heard: [String], endingAt end: Int, in words: [Word]) -> Double {
        var score = 0.0
        var scriptIndex = end
        var heardIndex = heard.count - 1
        var slack = 1
        while heardIndex >= 0, scriptIndex >= 0 {
            let match = similar(heard[heardIndex], words[scriptIndex].text)
            if match > 0 {
                score += match
                heardIndex -= 1
                scriptIndex -= 1
            } else if slack > 0, scriptIndex > 0, similar(heard[heardIndex], words[scriptIndex - 1].text) > 0 {
                slack -= 1  // a script word skipped
                scriptIndex -= 1
            } else if slack > 0, heardIndex > 0, similar(heard[heardIndex - 1], words[scriptIndex].text) > 0 {
                slack -= 1  // a word ad-libbed or misheard
                heardIndex -= 1
            } else {
                break
            }
        }
        // The newest heard word must be the last one matched, or it isn't "here".
        return similar(heard.last ?? "", words[end].text) > 0 ? score : 0
    }

    /// 1 for the same word, 0.8 for a close spelling of a longer word, else 0.
    static func similar(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        guard a.count >= 4, b.count >= 4, abs(a.count - b.count) <= 1 else { return 0 }
        return distance(a, b) <= 1 ? 0.8 : 0
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return row[b.count]
    }

    static func place(of index: Int, in words: [Word]) -> Place {
        let line = words[index].line
        let lineWords = words.indices.filter { words[$0].line == line }
        let position = (lineWords.firstIndex(of: index) ?? 0) + 1
        return Place(word: index, line: line, fraction: Double(position) / Double(max(1, lineWords.count)))
    }
}
