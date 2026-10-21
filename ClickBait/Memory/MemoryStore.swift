import AppKit
import ClickBaitCore
import OSLog

/// The user's remembered facts on disk (`Memory` in Core holds the rules): a plain text file
/// they can open, edit or empty, `~/Library/Application Support/ClickBait/NOTES.md`. Only text
/// the user chose goes in; nothing is sent anywhere but the local model.
@MainActor
final class MemoryStore {
    static let shared = MemoryStore()

    let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ClickBait", isDirectory: true).appendingPathComponent("NOTES.md")
    }()

    /// Read fresh each time: the user may have edited the file since.
    var memory: Memory {
        Memory(file: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    @discardableResult
    func remember(_ fact: String) -> Memory.Outcome {
        var memory = memory
        let outcome = memory.add(fact, on: Date())
        if case .saved = outcome { write(memory) }
        return outcome
    }

    @discardableResult
    func forget(_ thing: String) -> Int {
        var memory = memory
        let removed = memory.forget(thing)
        if removed > 0 { write(memory) }
        return removed
    }

    /// The notes folder (`NoteFolder`): the user's own `.md` files, read fresh for each question.
    let notesFolder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ClickBait/Notes", isDirectory: true)
    }()

    /// Newest first; at most 100 files of 256 KB each, so a stray big file can't slow an answer.
    var notes: [(name: String, text: String)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: notesFolder, includingPropertiesForKeys: keys)) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "md" && ((try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) <= 256_000 }
            .sorted { modified($0) > modified($1) }
            .prefix(100)
            .compactMap { url in (try? String(contentsOf: url, encoding: .utf8)).map { (url.deletingPathExtension().lastPathComponent, $0) } }
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    /// What goes in a prompt for `question`: remembered facts, then matching note lines.
    func block(for question: String) -> String? {
        let blocks = [memory.block(for: question), NoteFolder.block(for: question, notes: notes)].compactMap { $0 }
        return blocks.isEmpty ? nil : blocks.joined(separator: "\n\n")
    }

    /// Opens the notes folder in Finder (made first if it isn't there yet).
    func revealNotes() {
        try? FileManager.default.createDirectory(at: notesFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(notesFolder)
    }

    /// Opens the file in the user's text editor (made first if there's nothing yet).
    func reveal() {
        if !FileManager.default.fileExists(atPath: url.path) { write(Memory(file: "")) }
        NSWorkspace.shared.open(url)
    }

    /// What to say back for the user's own words ("remember …", "forget …").
    func reply(to command: Memory.Command) -> (message: String, ok: Bool) {
        switch command {
        case .remember(let fact):
            switch remember(fact) {
            case .saved(let text): return ("Got it, I'll remember: \(text)", true)
            case .refusedSecret: return ("I won't keep passwords, codes, keys or card numbers.", false)
            case .empty: return ("What should I remember?", false)
            }
        case .forget(let thing):
            let removed = forget(thing)
            return removed == 0 ? ("I didn't have anything about that.", false)
                : ("Forgotten\(removed > 1 ? " (\(removed) lines)" : "").", true)
        }
    }

    private func write(_ memory: Memory) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try memory.file.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Log.app.error("Couldn't save what to remember: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Asks the user to check (and edit) a line before it's remembered: from the Services menu
/// and the chat's Remember button. Nil if they cancel.
@MainActor
enum RememberPrompt {
    static func confirm(_ suggestion: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Remember this?"
        alert.informativeText = "ClickBait will use it in later answers. Edit it first if you like. It stays on this Mac."
        let field = NSTextField(string: String(suggestion.prefix(200)))
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        field.setAccessibilityLabel("The line to remember")
        alert.accessoryView = field
        alert.addButton(withTitle: "Remember")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Shows how it went, in a small alert (the Services menu has no chat to answer in).
    static func tell(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }
}

/// Saved answers on disk (`SavedAnswer` in Core formats them).
@MainActor
enum AnswerArchive {
    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ClickBait", isDirectory: true).appendingPathComponent("answers", isDirectory: true)
    }()

    /// Writes the chat's turns; returns the file, or nil if it couldn't be written.
    static func save(_ turns: [(role: SavedAnswer.Role, text: String)]) -> URL? {
        guard turns.contains(where: { $0.role == .assistant }) else { return nil }
        let now = Date()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            let question = turns.first { $0.role == .user }?.text ?? ""
            let name = SavedAnswer.unique(SavedAnswer.fileName(question: question, date: now), existing: existing)
            let url = folder.appendingPathComponent(name)
            try SavedAnswer.markdown(turns, date: now).write(to: url, atomically: true, encoding: .utf8)
            Log.app.notice("Saved an answer (\(turns.count, privacy: .public) turns)")
            return url
        } catch {
            Log.app.error("Couldn't save the answer: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Shows the folder (or a just-saved file) in Finder.
    static func reveal(_ file: URL? = nil) {
        if let file {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
    }
}

/// The Services menu's "Remember with ClickBait": highlight text in any app, right-click ▸
/// Services ▸ Remember with ClickBait, check the line, Remember (C5). Declared under
/// `NSServices` in project.yml.
@MainActor
final class ServicesProvider: NSObject {
    @objc func rememberSelection(_ pasteboard: NSPasteboard, userData: String?,
                                 error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            error.pointee = "Nothing was selected." as NSString
            return
        }
        guard let line = RememberPrompt.confirm(text) else { return }
        let reply = MemoryStore.shared.reply(to: .remember(line))
        Log.app.notice("Memory (Services): \(reply.ok ? "done" : "not done", privacy: .public)")
        if !reply.ok { RememberPrompt.tell(reply.message) }
    }
}
