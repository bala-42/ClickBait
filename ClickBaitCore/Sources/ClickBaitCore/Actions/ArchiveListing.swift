import Foundation

/// An archive's contents from `tar -tvf` (macOS's libarchive tar, any format it reads), for
/// "what's in this zip?" (user's ask, 2026-11-02).
public enum ArchiveListing {
    public struct Entry: Equatable, Sendable {
        public let path: String
        public let bytes: Int64
        public var isFolder: Bool { path.hasSuffix("/") }
    }

    /// One entry per line: permissions, links, owner, group, size, three date fields, the name
    /// (which may hold spaces). Finder's own leftovers (__MACOSX, .DS_Store) are left out.
    public static func entries(_ listing: String) -> [Entry] {
        let line = try? NSRegularExpression(pattern: #"^\S{10}\s+\d+\s+\S+\s+\S+\s+(\d+)\s+\S+\s+\S+\s+\S+\s(.+)$"#)
        return listing.split(separator: "\n").compactMap { raw in
            let text = String(raw)
            guard let match = line?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let size = Range(match.range(at: 1), in: text), let name = Range(match.range(at: 2), in: text) else { return nil }
            let path = String(text[name])
            guard !path.hasPrefix("__MACOSX"), !path.hasSuffix(".DS_Store") else { return nil }
            return Entry(path: path, bytes: Int64(text[size]) ?? 0)
        }
    }

    /// What's at the top: files by name, folders with a "/" ("photos/"), in order, once each.
    public static func topLevel(_ entries: [Entry]) -> [String] {
        var seen = Set<String>()
        return entries.compactMap { entry in
            let parts = entry.path.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
            guard let first = parts.first else { return nil }
            let name = parts.count > 1 || entry.isFolder ? first + "/" : String(first)
            return seen.insert(name).inserted ? name : nil
        }
    }
}
