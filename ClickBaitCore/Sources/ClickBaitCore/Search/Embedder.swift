import Foundation

/// Meaning vectors from nomic-embed-text through Ollama: ClickBait's standard embedding model
/// (user's ask, 2026-11-01), downloaded with every brain. Local only. nomic wants a label in
/// front of each text ("search_query: " or "search_document: "); without it results are worse.
public enum Embedder {
    public static let model = "nomic-embed-text"

    public enum Role: String, Sendable {
        case query = "search_query: "
        case document = "search_document: "
    }

    /// The texts' vectors in order, or nil when Ollama or the model isn't there. The model is
    /// let go after a minute, so it never holds memory the brain needs.
    public static func vectors(_ texts: [String], as role: Role, within seconds: TimeInterval = 60) async -> [[Float]]? {
        guard !texts.isEmpty else { return [] }
        var request = URLRequest(url: OllamaProvider.baseURL.appending(path: "api/embed"), timeoutInterval: seconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // nomic reads up to ~2,000 words; the opening is what a search needs.
        let input = texts.map { role.rawValue + String($0.prefix(2_000)) }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "input": input, "keep_alive": "1m"])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["embeddings"] as? [[NSNumber]], rows.count == texts.count else { return nil }
        return rows.map { $0.map(\.floatValue) }
    }
}
