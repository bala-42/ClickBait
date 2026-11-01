import Foundation

/// The local brain's two jobs on a Studio script (user's ask, 2026-11-01): make it speakable
/// (how people actually talk) and create its cues. Pure: the prompts, and checks on what
/// comes back.
public enum ScriptRewrite {
    public enum Job: Sendable { case speakable, cuesOnly }

    public static func prompt(_ job: Job, script: String) -> String {
        switch job {
        case .speakable:
            """
            Rewrite this script so it sounds natural spoken aloud on camera, like a friendly \
            person explaining it to a colleague: conversational, contractions, plain words, \
            mostly short sentences that still flow into each other (not choppy fragments). \
            Keep every fact, name, number and the order of ideas; don't add new claims. Split it into sections, each \
            starting with a heading line "# " and two to five words naming it.
            Reply with only the script, no preamble, no notes.

            SCRIPT:
            \(script)
            """
        case .cuesOnly:
            """
            Add section headings to this script. Insert a line "# " plus two to five words before \
            each new section. Do NOT change, add or remove any other word, and keep every line \
            break. Reply with only the script with its headings, no preamble, no notes.

            SCRIPT:
            \(script)
            """
        }
    }

    /// The brain's reply as a script: code fences, a "Here's…" line and stray quotes removed.
    public static func cleaned(_ reply: String) -> String {
        var lines = reply.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        if let first = lines.first?.lowercased(), first.hasPrefix("here") || first.hasPrefix("sure"), first.hasSuffix(":") {
            lines.removeFirst()
        }
        // "## Intro" or "**Intro**" headings as the cue rules read them.
        lines = lines.map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("**"), trimmed.hasSuffix("**"), trimmed.count > 4 {
                return "# " + trimmed.dropFirst(2).dropLast(2)
            }
            return line
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cues only: the reply keeps every word of the script (headings aside). False means the
    /// brain rewrote it, and the original is kept.
    public static func keepsWords(original: String, rewritten: String) -> Bool {
        let words = { (text: String) -> [String] in
            text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
                .flatMap { ScriptFollower.normalized(String($0)) }
        }
        return words(original) == words(rewritten)
    }

    /// A speakable rewrite that's plausible: cues found, and not far shorter or longer than
    /// the original (a reply that summarised or rambled is refused).
    public static func plausible(original: String, rewritten: String) -> Bool {
        let before = ScriptFollower.normalized(original).count, after = ScriptFollower.normalized(rewritten).count
        guard before > 0 else { return false }
        let ratio = Double(after) / Double(before)
        let headings = rewritten.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        return ratio > 0.6 && ratio < 1.6 && headings
    }
}

/// Add cues = organize the content into sections by topic and make those the cues (user's ask,
/// 2026-11-01: "it should organize whatever content i have into [cues]"). ClickBait numbers
/// the script's own sentences, the brain only says which go together and what each group is
/// called (a structured answer), and the script is rebuilt from the exact sentences — none can
/// be reworded or lost. Pure.
public enum ScriptOrganizer {
    public struct Section: Decodable, Equatable, Sendable {
        public let title: String
        public let sentences: [Int]
        public init(title: String, sentences: [Int]) { self.title = title; self.sentences = sentences }
    }

    /// The script's sentences in order, old headings and dividers left out.
    public static func sentences(of script: String) -> [String] {
        let body = script.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("#") && !(trimmed.count >= 3 && trimmed.allSatisfy { "-*_=".contains($0) })
        }.joined(separator: "\n")
        var found: [String] = []
        body.enumerateSubstrings(in: body.startIndex..<body.endIndex, options: .bySentences) { sentence, _, _, _ in
            let text = (sentence ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { found.append(text) }
        }
        return found
    }

    public static func prompt(_ sentences: [String]) -> String {
        let listing = sentences.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return """
            Group these numbered sentences of a script into sections by topic. Each section gets a \
            title of two to five words. Put every sentence in exactly one section; sentences about \
            the same thing go together; order the sections the way a talk would flow (greeting \
            first, goodbye last).

            \(listing)
            """
    }

    /// The answer's shape, for Ollama's structured output.
    public static var schema: [String: Any] { [
        "type": "object",
        "properties": ["sections": ["type": "array", "items": [
            "type": "object",
            "properties": ["title": ["type": "string"], "sentences": ["type": "array", "items": ["type": "integer"]]],
            "required": ["title", "sentences"]
        ]]],
        "required": ["sections"]
    ] }

    /// The script rebuilt: "# Title" and its sentences, section by section. Every sentence
    /// appears once: repeats are dropped, and any the brain left out joins the section of the
    /// sentence just before it (else the first).
    public static func assemble(_ sentences: [String], sections: [Section]) -> String? {
        var groups: [(title: String, items: [Int])] = []
        var used = Set<Int>()
        for section in sections {
            let title = section.title.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "#*")))
            let items = section.sentences.filter { (1...sentences.count).contains($0) && used.insert($0).inserted }
            if !items.isEmpty, !title.isEmpty { groups.append((title, items)) }
        }
        guard !groups.isEmpty else { return nil }
        for missing in (1...sentences.count) where !used.contains(missing) {
            let home = groups.firstIndex { $0.items.contains(missing - 1) } ?? 0
            groups[home].items.append(missing)
            groups[home].items.sort()
        }
        return groups.map { group in
            "# \(group.title)\n" + group.items.map { sentences[$0 - 1] }.joined(separator: " ")
        }.joined(separator: "\n\n")
    }
}
