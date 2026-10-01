import ClickBaitCore
import Foundation
import Observation

/// User preferences, persisted in UserDefaults. Secrets (API keys) never go here;
/// they live in the Keychain.
@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let blocklist = "settings.blocklist"
        static let keepDebugCaptures = "settings.keepDebugCaptures"
        static let speechModel = "settings.speechModel"
        static func speechModelFolder(_ model: SpeechModel) -> String { "settings.speechModelFolder.\(model.rawValue)" }
    }

    @ObservationIgnored private let defaults: UserDefaults

    var blocklist: AppBlocklist {
        didSet { save(blocklist, forKey: Key.blocklist) }
    }

    /// Keep the most recent screenshot and recording in a temp folder for debugging.
    /// Off by default (CLAUDE.md privacy rules).
    var keepDebugCaptures: Bool {
        didSet { defaults.set(keepDebugCaptures, forKey: Key.keepDebugCaptures) }
    }

    var speechModel: SpeechModel {
        didSet { defaults.set(speechModel.rawValue, forKey: Key.speechModel) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        blocklist = Self.load(AppBlocklist.self, from: defaults, forKey: Key.blocklist) ?? .defaults
        keepDebugCaptures = defaults.bool(forKey: Key.keepDebugCaptures)
        speechModel = defaults.string(forKey: Key.speechModel).flatMap(SpeechModel.init(rawValue:)) ?? .default
    }

    /// Where a downloaded speech model lives, as reported by WhisperKit after download.
    func speechModelFolder(for model: SpeechModel) -> URL? {
        defaults.string(forKey: Key.speechModelFolder(model)).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func setSpeechModelFolder(_ folder: URL, for model: SpeechModel) {
        defaults.set(folder.path, forKey: Key.speechModelFolder(model))
    }

    private func save<T: Encodable>(_ value: T, forKey key: String) {
        do {
            defaults.set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            Log.app.error("Couldn't save setting \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, forKey key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
