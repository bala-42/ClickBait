import Foundation

/// Ollama `/api/chat` streaming: one JSON object per line.
public enum OllamaStreamDecoder {
    public static func decode(line: String) throws -> (text: String, done: Bool)? {
        guard !line.isEmpty else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            throw LLMError.invalidResponse("unreadable line from Ollama")
        }
        if let error = json["error"] as? String {
            throw LLMError.invalidResponse(error)
        }
        let message = json["message"] as? [String: Any]
        let text = message?["content"] as? String ?? ""
        let done = json["done"] as? Bool ?? false
        return (text, done)
    }
}
