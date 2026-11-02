import Foundation

/// Browsing an archive like a folder (user's ask, 2026-11-02, after MacPacker's "peek inside"):
/// a folder's children from tar's flat listing (folders made up from paths when the archive
/// doesn't list them), sizes summed for folders, search across all of it, archives inside it
/// to drill into, and where "extract all" should put things. The app reads and extracts.
public enum ArchiveTree {
    public struct Item: Identifiable, Equatable, Sendable {
        /// The path inside the archive ("photos/", "photos/cat.jpg").
        public let path: String
        public let name: String
        public let isFolder: Bool
        public let bytes: Int64
        public let modified: Date?
        public var id: String { path }
        /// Another archive inside this one, opened in place.
        public var isArchive: Bool { !isFolder && ArchiveTree.isArchiveName(name) }
    }

    /// What's directly in `folder` ("" for the top, else ending in "/"), folders first, by name.
    public static func children(of folder: String, in entries: [ArchiveListing.Entry], now: Date = Date()) -> [Item] {
        var files: [String: Item] = [:]
        var folders: [String: (bytes: Int64, date: Date?)] = [:]
        for entry in entries where entry.path.hasPrefix(folder) && entry.path != folder {
            let rest = entry.path.dropFirst(folder.count)
            let parts = rest.split(separator: "/", omittingEmptySubsequences: true)
            guard let first = parts.first else { continue }
            if parts.count > 1 || entry.isFolder {
                let path = folder + first + "/"
                let date = parts.count == 1 ? parseDate(entry.date, now: now) : folders[path]?.date
                folders[path] = ((folders[path]?.bytes ?? 0) + (entry.isFolder ? 0 : entry.bytes), date ?? folders[path]?.date)
            } else {
                files[entry.path] = Item(path: entry.path, name: String(first), isFolder: false, bytes: entry.bytes, modified: parseDate(entry.date, now: now))
            }
        }
        let folderItems = folders.map { path, info in
            Item(path: path, name: String(path.dropLast().split(separator: "/").last ?? ""), isFolder: true, bytes: info.bytes, modified: info.date)
        }
        let byName: (Item, Item) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return folderItems.sorted(by: byName) + files.values.sorted(by: byName)
    }

    /// Everything whose name holds `query`, anywhere in the archive.
    public static func search(_ query: String, in entries: [ArchiveListing.Entry], now: Date = Date()) -> [Item] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return entries.compactMap { entry in
            let name = String(entry.path.split(separator: "/").last ?? "")
            guard name.localizedCaseInsensitiveContains(query) else { return nil }
            return Item(path: entry.path, name: name, isFolder: entry.isFolder, bytes: entry.bytes, modified: parseDate(entry.date, now: now))
        }
    }

    /// Archive kinds macOS's tar reads, drilled into in place.
    public static func isArchiveName(_ name: String) -> Bool {
        let lower = name.lowercased()
        let kinds = [".zip", ".tar", ".tgz", ".tar.gz", ".tbz", ".tar.bz2", ".txz", ".tar.xz", ".7z", ".rar", ".cbz", ".cbr", ".jar", ".iso", ".xar", ".cpio"]
        return kinds.contains { lower.hasSuffix($0) }
    }

    /// A path as a tar pattern (tar reads its member arguments as wildcards): `*`, `?`, `[`
    /// and `\` escaped, so "notes[1].txt" means just that file.
    public static func tarPattern(_ path: String) -> String {
        path.reduce(into: "") { out, character in
            if "*?[\\".contains(character) { out.append("\\") }
            out.append(character)
        }
    }

    /// "Extract all" (MacPacker's smart extraction): one item at the top lands as itself
    /// beside the archive; several land in a folder named after the archive — a single folder
    /// is never nested inside another of the same name.
    public static func extractsIntoOwnFolder(_ entries: [ArchiveListing.Entry]) -> Bool {
        ArchiveListing.topLevel(entries).count != 1
    }

    /// tar's dates: "Nov  2 18:07" (this year, or last if that's ahead) or "Mar  4  2024", or
    /// day first as some Macs print them ("2 Nov 18:07").
    public static func parseDate(_ text: String, now: Date = Date()) -> Date? {
        var parts = text.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3 else { return nil }
        if parts[0].allSatisfy(\.isNumber) { parts.swapAt(0, 1) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if parts[2].contains(":") {
            let year = Calendar.current.component(.year, from: now)
            formatter.dateFormat = "MMM d HH:mm yyyy"
            guard let date = formatter.date(from: "\(parts[0]) \(parts[1]) \(parts[2]) \(year)") else { return nil }
            return date > now.addingTimeInterval(86_400) ? Calendar.current.date(byAdding: .year, value: -1, to: date) : date
        }
        formatter.dateFormat = "MMM d yyyy"
        return formatter.date(from: "\(parts[0]) \(parts[1]) \(parts[2])")
    }
}
