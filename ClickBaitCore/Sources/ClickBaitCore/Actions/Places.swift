import Foundation

/// Folders the user can name out loud: "in Downloads", "on the Desktop".
public enum Place: String, CaseIterable, Codable, Sendable {
    case desktop, downloads, documents, home, applications
    case iCloudDrive = "icloud_drive"
    case pictures, music, movies

    /// As said back to the user: "Made “Receipts” in Downloads".
    public var displayName: String {
        switch self {
        case .desktop: "the Desktop"
        case .downloads: "Downloads"
        case .documents: "Documents"
        case .home: "your home folder"
        case .applications: "Applications"
        case .iCloudDrive: "iCloud Drive"
        case .pictures: "Pictures"
        case .music: "the Music folder"
        case .movies: "Movies"
        }
    }

    /// The place named at the start of `words` (after "my"/"the"), and how many words
    /// it took. Music, Pictures, Movies and Home are also apps (or ordinary words), so
    /// they only count with "folder" unless `strict` is false.
    static func named(at words: ArraySlice<String>, strict: Bool) -> (Place, Int)? {
        var rest = words
        var skipped = 0
        while let first = rest.first, ["my", "the", "your"].contains(first) {
            rest = rest.dropFirst()
            skipped += 1
        }
        guard let word = rest.first else { return nil }
        let followedByFolder = rest.dropFirst().first == "folder"
        let place: Place?
        var used = 1
        switch word {
        case "desktop": place = .desktop
        case "downloads", "download": place = .downloads
        case "documents", "docs": place = .documents
        case "applications", "apps": place = .applications
        case "icloud":
            place = .iCloudDrive
            if rest.dropFirst().first == "drive" { used = 2 }
        case "home": place = (followedByFolder || !strict) ? .home : nil
        case "pictures": place = (followedByFolder || !strict) ? .pictures : nil
        case "music": place = (followedByFolder || !strict) ? .music : nil
        case "movies": place = (followedByFolder || !strict) ? .movies : nil
        default: place = nil
        }
        guard let place else { return nil }
        if rest.dropFirst(used).first == "folder" { used += 1 }
        return (place, skipped + used)
    }
}

/// Names for new folders and renamed files, as the user said them.
public enum SpokenName {
    /// "…called Receipts." → "Receipts"; nil if nothing usable follows.
    public static func after(_ markers: [String], in transcript: String) -> String? {
        let pattern = "(?i)\\b(?:" + markers.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")\\s+(.+)$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: transcript, range: NSRange(transcript.startIndex..., in: transcript)),
              let range = Range(match.range(at: 1), in: transcript)
        else { return nil }
        return clean(String(transcript[range]))
    }

    /// "Rename this to Invoice March", "rename it Invoice March", "rename the file as X".
    public static func renameTarget(in transcript: String) -> String? {
        let pattern = "(?i)\\brename\\s+(?:(?:this|that|it|the\\s+(?:selected\\s+)?(?:file|folder|item))\\s+)?(?:to\\s+|as\\s+)?(.+)$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: transcript, range: NSRange(transcript.startIndex..., in: transcript)),
              let range = Range(match.range(at: 1), in: transcript)
        else { return nil }
        return clean(String(transcript[range]))
    }

    /// Trims spaces, the sentence's final punctuation, a trailing "please" and quotes.
    static func clean(_ text: String) -> String? {
        var name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = true
        while changed {
            changed = false
            for suffix in [".", "!", "?", ",", ";", " please", ", please"] where name.lowercased().hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’").union(.whitespaces))
        return name.isEmpty ? nil : name
    }

    /// A name that's safe as a single file name: no path separators, not hidden, not
    /// `.`/`..`, not absurdly long. Nil if it can't be used.
    public static func validated(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("."), !trimmed.contains("/"), !trimmed.contains(":"),
              trimmed.utf8.count <= 200
        else { return nil }
        return trimmed
    }
}

/// Free text the user dictated into a note or reminder: everything after the keyword,
/// minus connecting words ("make a note *that* …", "remind me *to* …"), first letter
/// capitalised, original casing otherwise kept.
public enum SpokenContent {
    public static func after(_ markers: [String], in transcript: String) -> String? {
        let pattern = "(?i)\\b(?:" + markers.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")\\b(.*)$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: transcript, range: NSRange(transcript.startIndex..., in: transcript)),
              let range = Range(match.range(at: 1), in: transcript)
        else { return nil }
        var text = String(transcript[range]).trimmingCharacters(in: .whitespaces)
        // Connectors between the keyword and the content.
        let connectors = [":", ",", "-", "—", "that says", "saying", "says", "that", "to say", "to", "about", "for", "of"]
        var changed = true
        while changed {
            changed = false
            for connector in connectors {
                let lower = text.lowercased()
                let isWord = connector.first?.isLetter == true
                guard lower.hasPrefix(connector),
                      !isWord || lower.count == connector.count || lower.dropFirst(connector.count).first == " "
                else { continue }
                text = String(text.dropFirst(connector.count)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        guard var cleaned = SpokenName.clean(text) else { return nil }
        if let first = cleaned.first, first.isLowercase { cleaned = first.uppercased() + cleaned.dropFirst() }
        return cleaned
    }
}

/// A folder the user names by speaking about it: "the receipts folder" → "receipts".
public enum FolderReference {
    /// Words that mean "the folder ClickBait just made".
    public static let justMade: Set<String> = ["new folder", "the new folder", "untitled folder", "that folder", "the folder",
                                               "this folder", "it", "the one i just made", "the folder i just made"]

    public static func clean(_ text: String) -> String {
        var name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = name.lowercased()
        if justMade.contains(lower) { return "new folder" }
        for prefix in ["the ", "my ", "a ", "that "] where name.lowercased().hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }
        if justMade.contains(name.lowercased()) { return "new folder" }
        if name.lowercased().hasSuffix(" folder") { name = String(name.dropLast(" folder".count)) }
        return SpokenName.clean(name) ?? name
    }

    public static func meansJustMade(_ name: String) -> Bool {
        name.lowercased() == "new folder"
    }
}
