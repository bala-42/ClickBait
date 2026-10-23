import CryptoKit
import Foundation

/// Covers downloaded with Internet Mode on (Spotify's, YouTube thumbnails) are kept on the
/// Mac, so the notch can show a track it has seen before with Internet Mode off (user's ask,
/// 2026-10-23). Pure: the file names and which files to drop; the app reads and writes.
public enum CoverStore {
    /// The newest this many stay; the rest go, least recently shown first.
    public static let limit = 500

    /// A stable, file-safe name for a track's key ("player|title|artist", "youtube|id"),
    /// hashed so no track names sit in the folder's listing.
    public static func fileName(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".cover"
    }

    /// The files to delete so at most `limit` remain: the least recently used ones.
    public static func overflow(_ files: [(name: String, used: Date)], limit: Int = limit) -> [String] {
        guard files.count > limit else { return [] }
        return files.sorted { $0.used < $1.used }.prefix(files.count - limit).map(\.name)
    }
}
