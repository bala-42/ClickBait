import Foundation
import Security

/// The Anthropic provider was removed (2026-10-10: no paid keys). Once, on the first launch
/// after that, its saved choice and model name are forgotten — so a user who had it
/// selected is quietly on Ollama — and any API key it kept in the Keychain is deleted.
enum LegacyCloudSettings {
    private static let doneKey = "settings.removedAnthropicProvider"

    static func remove(from defaults: UserDefaults) {
        guard !defaults.bool(forKey: doneKey) else { return }
        let hadCloud = defaults.string(forKey: "settings.provider") == "anthropic"
        defaults.removeObject(forKey: "settings.provider")
        defaults.removeObject(forKey: "settings.anthropicModel")
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.clickbait.ClickBait",
            kSecAttrAccount as String: "anthropic-api-key",
        ]
        let status = SecItemDelete(query as CFDictionary)
        defaults.set(true, forKey: doneKey)
        Log.app.notice("""
            Removed the Anthropic provider's settings (was selected: \(hadCloud, privacy: .public); \
            Keychain key: \(status == errSecSuccess ? "deleted" : status == errSecItemNotFound ? "none" : "error \(status)", privacy: .public))
            """)
    }
}
