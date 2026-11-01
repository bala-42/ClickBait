import Foundation

/// C5's notes folder (user's choice, 2026-10-21; idea from Sentient OS's Markdown knowledge
/// base): every `.md` file the user keeps in `~/Library/Application Support/ClickBait/Notes/`
/// is plain text ClickBait may draw on. Only lines sharing a word with the question go to the
/// local model, within `promptBudget`; headings, empty lines and anything that looks secret
/// (`Memory.looksSecret`: passwords, keys, card and ID numbers) are left out. Pure.
///
///     NoteFolder.block(for: "when is the Atlas launch?", notes: [("work", "- Atlas launch: 3 Nov")])
///     // "From the user's notes …\n- Atlas launch: 3 Nov (work)"
public enum NoteFolder {
    public static let promptBudget = 800

    /// Every line that may go to the model, with its file name: no headings, nothing secret.
    public static func lines(in notes: [(name: String, text: String)]) -> [(line: String, entry: String)] {
        var found: [(line: String, entry: String)] = []
        for note in notes {
            for raw in note.text.split(whereSeparator: \.isNewline) {
                let line = Memory.tidy(String(raw).trimmingCharacters(in: CharacterSet(charactersIn: " \t-*+>")))
                guard line.count >= 3, !raw.trimmingCharacters(in: .whitespaces).hasPrefix("#"), !Memory.looksSecret(line) else { continue }
                found.append((line, "\(line) (\(note.name))"))
            }
        }
        return found
    }

    /// `notes`: (file name without `.md`, its text), in the order to prefer. `similarity`:
    /// each line's meaning match with the question (nomic, 0…1) when known: a line close to
    /// the best one counts even without a shared word ("teeth cleaning" → "Dentist: Dr Lim").
    /// Measured 2026-11-01 on 10 questions: shared words found the right line 2 times, nomic 9.
    public static func relevant(to question: String, notes: [(name: String, text: String)],
                                similarity: [String: Double] = [:]) -> [String] {
        let words = Memory.contentWords(question)
        guard !words.isEmpty || !similarity.isEmpty else { return [] }
        let best = similarity.values.max() ?? 0
        var candidates = lines(in: notes).filter { candidate in
            let score = similarity[candidate.line] ?? 0
            return !Memory.contentWords(candidate.line).isDisjoint(with: words) || (score >= 0.55 && score >= best - 0.06)
        }
        if !similarity.isEmpty {
            candidates = candidates.enumerated().sorted { a, b in
                let (sa, sb) = (similarity[a.element.line] ?? 0, similarity[b.element.line] ?? 0)
                return sa != sb ? sa > sb : a.offset < b.offset
            }.map(\.element)
        }
        var picked: [String] = []
        var used = 0
        for candidate in candidates {
            guard used + candidate.entry.count <= promptBudget, !picked.contains(candidate.entry) else { continue }
            picked.append(candidate.entry)
            used += candidate.entry.count
        }
        return picked
    }

    /// The prompt block, or nil when no line fits the question.
    public static func block(for question: String, notes: [(name: String, text: String)],
                             similarity: [String: Double] = [:]) -> String? {
        let lines = relevant(to: question, notes: notes, similarity: similarity)
        guard !lines.isEmpty else { return nil }
        return (["From the user's notes (their own files, by file name; use them when they fit):"]
            + lines.map { "- \($0)" }).joined(separator: "\n")
    }
}
