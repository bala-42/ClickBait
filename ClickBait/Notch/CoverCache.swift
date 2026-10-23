import AppKit
import ClickBaitCore

/// The covers kept on this Mac (`CoverStore`): in Application Support, one file per track,
/// named by a hash of its key. Saved after a download with Internet Mode on; read when
/// Internet Mode is off (or a download fails). Nothing here touches the network.
enum CoverCache {
    static let folder: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "ClickBait/Covers", directoryHint: .isDirectory)
    }()

    /// The saved cover for a track, marked as just used.
    static func image(for key: String) -> NSImage? {
        let file = folder.appending(path: CoverStore.fileName(for: key))
        guard let data = try? Data(contentsOf: file), let image = NSImage(data: data) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return image
    }

    /// Keeps a downloaded cover, then trims the folder to `CoverStore.limit` (off the main thread).
    static func save(_ data: Data, for key: String) {
        let name = CoverStore.fileName(for: key)
        Task.detached(priority: .utility) {
            let manager = FileManager.default
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: folder.appending(path: name), options: .atomic)
            let files = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let dated = files.map { url in
                (name: url.lastPathComponent,
                 used: (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
            for old in CoverStore.overflow(dated) { try? manager.removeItem(at: folder.appending(path: old)) }
        }
    }

    static var count: Int { (try? FileManager.default.contentsOfDirectory(atPath: folder.path).count) ?? 0 }

    static func clear() { try? FileManager.default.removeItem(at: folder) }
}
