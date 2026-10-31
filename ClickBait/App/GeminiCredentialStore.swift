import Foundation

/// Stores the user's Gemini API key in ClickBait's local preferences.
enum GeminiKeyStore {
    private static let key = "settings.geminiAPIKey"

    static func read() -> String? {
        guard let value = UserDefaults.standard.string(forKey: key), !value.isEmpty else { return nil }
        return value
    }

    static func save(_ value: String) {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { delete() }
        else { UserDefaults.standard.set(cleaned, forKey: key) }
    }

    static func delete() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
