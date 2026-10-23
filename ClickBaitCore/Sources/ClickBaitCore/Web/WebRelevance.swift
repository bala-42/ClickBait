import Foundation

/// Whether a looked-up passage is actually about the search: Wikipedia's search, the only
/// source without SearXNG, returned "Gab (social network)" and "List of scams" for
/// "passport renewal fee", and they were credited as sources (try-list c34, 2026-10-23).
/// A passage must contain the query's key words: all of them for up to 3, else 60 %.
public enum WebRelevance {
    static let ignored: Set<String> = ["the", "and", "for", "how", "what", "who", "why", "when", "where", "which",
                                       "does", "did", "are", "was", "were", "is", "a", "an", "of", "to", "in", "on",
                                       "with", "about", "from", "my", "your", "it", "this", "that", "much", "many",
                                       "can", "should", "will", "do", "be", "or", "at", "by", "up", "out", "look"]

    /// The query's key words, lowercased (two letters or more, filler dropped).
    static func keyWords(_ query: String) -> [String] {
        let words = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var seen = Set<String>()
        return words.filter { $0.count >= 2 && !ignored.contains($0) && seen.insert($0).inserted }
    }

    public static func isRelevant(title: String, text: String, query: String) -> Bool {
        let words = keyWords(query)
        guard !words.isEmpty else { return true }
        let haystack = (title + " " + text).lowercased()
        let found = words.filter { haystack.contains($0) }.count
        let needed = words.count <= 3 ? words.count : Int((Double(words.count) * 0.6).rounded(.up))
        return found >= needed
    }
}
