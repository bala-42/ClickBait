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
