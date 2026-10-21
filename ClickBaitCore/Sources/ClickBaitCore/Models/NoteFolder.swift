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

    /// `notes`: (file name without `.md`, its text), in the order to prefer.
    public static func relevant(to question: String, notes: [(name: String, text: String)]) -> [String] {
        let words = Memory.contentWords(question)
        guard !words.isEmpty else { return [] }
        var picked: [String] = []
        var used = 0
        for note in notes {
            for raw in note.text.split(whereSeparator: \.isNewline) {
                let line = Memory.tidy(String(raw).trimmingCharacters(in: CharacterSet(charactersIn: " \t-*+>")))
                guard line.count >= 3, !raw.trimmingCharacters(in: .whitespaces).hasPrefix("#"),
                      !Memory.contentWords(line).isDisjoint(with: words), !Memory.looksSecret(line) else { continue }
                let entry = "\(line) (\(note.name))"
                guard used + entry.count <= promptBudget, !picked.contains(entry) else { continue }
                picked.append(entry)
                used += entry.count
            }
        }
        return picked
    }

    /// The prompt block, or nil when no line fits the question.
    public static func block(for question: String, notes: [(name: String, text: String)]) -> String? {
        let lines = relevant(to: question, notes: notes)
        guard !lines.isEmpty else { return nil }
        return (["From the user's notes (their own files, by file name; use them when they fit):"]
            + lines.map { "- \($0)" }).joined(separator: "\n")
    }
}
