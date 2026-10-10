import ClickBaitCore
import Foundation
import Observation

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let blocklist = "settings.blocklist"
        static let keepDebugCaptures = "settings.keepDebugCaptures"
        static let speechModel = "settings.speechModel"
        static let ollamaModel = "settings.ollamaModel"
        static let ollamaFastModel = "settings.ollamaFastModel"
        static let speakAnswers = "settings.speakAnswers"
        static let voiceIdentifier = "settings.voiceIdentifier"
        static let speechRate = "settings.speechRate"
        static let commandsEnabled = "settings.commandsEnabled"
        static let allowedShortcuts = "settings.allowedShortcuts"
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

    /// Internet Mode (🔒/🌐): off at every launch, never saved, switched from the menu bar.
    @ObservationIgnored let internet = InternetMode()
    /// Its free, keyless lookups (one ephemeral session for the app's life).
    @ObservationIgnored let web = WebFetcher()

    var speechModel: SpeechModel {
        didSet { defaults.set(speechModel.rawValue, forKey: Key.speechModel) }
    }

    var ollamaModel: String {
        didSet { defaults.set(ollamaModel, forKey: Key.ollamaModel) }
    }

    /// Reads orders ("move these to Documents"): a text job where speed matters most.
    var ollamaFastModel: String {
        didSet { defaults.set(ollamaFastModel, forKey: Key.ollamaFastModel) }
    }

    /// Read answers aloud (on-device system voices).
    var speakAnswers: Bool {
        didSet { defaults.set(speakAnswers, forKey: Key.speakAnswers) }
    }

    /// A system voice identifier; nil means the best voice for the system language.
    var voiceIdentifier: String? {
        didSet { defaults.set(voiceIdentifier, forKey: Key.voiceIdentifier) }
    }

    /// AVSpeechUtterance rate (0…1, system default 0.5).
    var speechRate: Double {
        didSet { defaults.set(speechRate, forKey: Key.speechRate) }
    }

    static let defaultSpeechRate = 0.52

    /// Carry out direct spoken orders (open apps, volume, Dark Mode, allowed shortcuts).
    var commandsEnabled: Bool {
        didSet { defaults.set(commandsEnabled, forKey: Key.commandsEnabled) }
    }

    /// Shortcuts the user ticked. Being on this list is the permission to run on command.
    var allowedShortcuts: [String] {
        didSet { defaults.set(allowedShortcuts, forKey: Key.allowedShortcuts) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        blocklist = Self.load(AppBlocklist.self, from: defaults, forKey: Key.blocklist) ?? .defaults
        keepDebugCaptures = defaults.bool(forKey: Key.keepDebugCaptures)
        speechModel = defaults.string(forKey: Key.speechModel).flatMap(SpeechModel.init(rawValue:)) ?? .default
        ollamaModel = Self.nonEmpty(defaults.string(forKey: Key.ollamaModel)) ?? OllamaProvider.defaultModel
        ollamaFastModel = Self.nonEmpty(defaults.string(forKey: Key.ollamaFastModel)) ?? OllamaProvider.defaultFastModel
        speakAnswers = defaults.object(forKey: Key.speakAnswers) as? Bool ?? true
        voiceIdentifier = defaults.string(forKey: Key.voiceIdentifier)
        speechRate = defaults.object(forKey: Key.speechRate) as? Double ?? Self.defaultSpeechRate
        commandsEnabled = defaults.object(forKey: Key.commandsEnabled) as? Bool ?? true
        allowedShortcuts = defaults.stringArray(forKey: Key.allowedShortcuts) ?? []
        LegacyCloudSettings.remove(from: defaults)
    }

    /// Ollama on this Mac: the only provider (no paid keys, 2026-10-10).
    func makeProvider() -> OllamaProvider {
        OllamaProvider(model: ollamaModel.trimmingCharacters(in: .whitespaces),
                       fastModel: ollamaFastModel.trimmingCharacters(in: .whitespaces))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
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
