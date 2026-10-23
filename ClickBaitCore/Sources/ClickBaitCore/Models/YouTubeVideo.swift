import Foundation

/// A YouTube video open in a browser tab, for the notch's player card (user's choice,
/// 2026-10-23): its title from the tab, its thumbnail as the cover (downloaded only with
/// Internet Mode on). Pure: the app reads the tabs and fetches the picture.
///
///     YouTubeVideo(url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=4", tabTitle: "(2) Song - YouTube")
///     // id "dQw4w9WgXcQ", title "Song"
public struct YouTubeVideo: Equatable, Sendable {
    public let id: String
    public let title: String

    /// Nil unless the URL is one video on YouTube (a watch page, a short, a youtu.be link).
    public init?(url: String, tabTitle: String) {
        guard let parts = URLComponents(string: url), let host = parts.host?.lowercased(),
              parts.scheme == "https" || parts.scheme == "http" else { return nil }
        let path = parts.path.split(separator: "/").map(String.init)
        let id: String?
        if host == "youtu.be" {
            id = path.first
        } else if host == "youtube.com" || host.hasSuffix(".youtube.com") {
            if path.first == "watch" {
                id = parts.queryItems?.first { $0.name == "v" }?.value
            } else if path.count >= 2, ["shorts", "live", "embed"].contains(path[0]) {
                id = path[1]
            } else {
                id = nil
            }
        } else {
            id = nil
        }
        // Video ids are 11 characters of [A-Za-z0-9_-]; anything else isn't one.
        guard let id, id.count == 11, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
        else { return nil }
        self.id = id
        self.title = Self.cleaned(tabTitle)
    }

    /// The 16:9 thumbnail (no letterbox bars, unlike hqdefault's 4:3).
    public var thumbnail: URL { URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg")! }

    /// "(3) Song - YouTube" → "Song".
    static func cleaned(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("("), let close = text.firstIndex(of: ")"),
           text[text.index(after: text.startIndex)..<close].allSatisfy(\.isNumber) {
            text = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        for suffix in ["- YouTube Music", "- YouTube"] where text.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        return text.isEmpty ? "YouTube" : text
    }
}
