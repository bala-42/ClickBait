import ClickBaitCore
import Foundation
import Observation

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let notchPanel = "settings.notchPanel"
        static let notchNote = "settings.notchNote"
        static let notchVolumeHUD = "settings.notchVolumeHUD"
        static let notchBrightnessHUD = "settings.notchBrightnessHUD"
        static let soundCues = "settings.soundCues"
        static let agentNotices = "settings.agentNotices"
        static let agentNoticesAsked = "settings.agentNoticesAsked"
        static let healthAlerts = "settings.healthAlerts"
        static let windowSwitcher = "settings.windowSwitcher"
        static let greetings = "settings.greetings"
        static let morningCards = "settings.morningCards"
        static let searchPhotos = "settings.searchPhotos"
        static let visionDescribe = "settings.vision.describe"
        static let visionPausedUntil = "settings.vision.pausedUntil"
        static let visionFolders = "settings.vision.folders"
        static let visionExcluded = "settings.vision.excluded"
        static let visionScreenshots = "settings.vision.screenshots"
        static let visionOnBattery = "settings.vision.onBattery"
        static let morningCardsShown = "settings.morningCardsShown"
        static let spotifyArtworkAlways = "settings.spotifyArtworkAlways"
        static let youtubeThumbnailsAlways = "settings.youtubeThumbnailsAlways"
        static let blocklist = "settings.blocklist"
        static let keepDebugCaptures = "settings.keepDebugCaptures"
        static let ignoreNotchInCaptures = "settings.ignoreNotchInCaptures"
        static let speechModel = "settings.speechModel"
        static let fillerWords = "settings.fillerWords"
        static let ollamaModel = "settings.ollamaModel"
        static let ollamaFastModel = "settings.ollamaFastModel"
        static let geminiInternetAnswers = "settings.geminiInternetAnswers"
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

    /// The user's own filler words and phrases, comma-separated, taken out of dictation.
    var fillerWords: String {
        didSet { defaults.set(fillerWords, forKey: Key.fillerWords) }
    }

    var ollamaModel: String {
        didSet { defaults.set(ollamaModel, forKey: Key.ollamaModel) }
    }

    /// Reads orders ("move these to Documents"): a text job where speed matters most.
    var ollamaFastModel: String {
        didSet { defaults.set(ollamaFastModel, forKey: Key.ollamaFastModel) }
    }

    /// Opt-in cloud answers for text-only web lookups, and only while Internet Mode is on.
    var geminiInternetAnswers: Bool {
        didSet { defaults.set(geminiInternetAnswers, forKey: Key.geminiInternetAnswers) }
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

    /// The notch panel (`NotchController`): on unless turned off from the menu bar.
    var notchPanelEnabled: Bool {
        didSet { defaults.set(notchPanelEnabled, forKey: Key.notchPanel) }
    }

    /// Keep ClickBait's own notch and windows out of screen captures ClickBait takes.
    var ignoreNotchInCaptures: Bool {
        didSet { defaults.set(ignoreNotchInCaptures, forKey: Key.ignoreNotchInCaptures) }
    }

    /// The volume keys show ClickBait's HUD in the notch instead of macOS's (they still work
    /// if this is off, or if ClickBait can't set the volume).
    /// A soft sound when a background job is done, and when ClickBait needs a yes (C6).
    var soundCues: Bool {
        didSet { defaults.set(soundCues, forKey: Key.soundCues) }
    }
    /// Claude Code and Codex notices by the cursor ("needs you", "finished"): ClickBait's hooks
    /// in Claude Code's settings are added while this is on and taken out when it's off.
    var agentNotices: Bool {
        didSet { defaults.set(agentNotices, forKey: Key.agentNotices) }
    }
    /// Mac health by the cursor (`HealthWatcher`): working hard, hot, low disk, low battery. On
    /// unless turned off.
    var healthAlerts: Bool {
        didSet { defaults.set(healthAlerts, forKey: Key.healthAlerts) }
    }
    /// ⌥⇥ window switching (`WindowSwitcher`); on unless turned off.
    var windowSwitcher: Bool {
        didSet { defaults.set(windowSwitcher, forKey: Key.windowSwitcher) }
    }
    /// Asked once whether to add the hooks (yes or no, never again).
    var agentNoticesAsked: Bool {
        didSet { defaults.set(agentNoticesAsked, forKey: Key.agentNoticesAsked) }
    }
    /// Vision Memory (`SearchIndex`'s pictures): reading and describing pictures at all.
    var visionDescribe: Bool {
        didSet { defaults.set(visionDescribe, forKey: Key.visionDescribe) }
    }
    /// Paused until then (Settings' Pause for an hour / until tomorrow).
    var visionPausedUntil: Date? {
        didSet { defaults.set(visionPausedUntil, forKey: Key.visionPausedUntil) }
    }
    /// Folders whose pictures are read (with their insides).
    var visionFolders: [String] {
        didSet { defaults.set(visionFolders, forKey: Key.visionFolders) }
    }
    /// Folders never looked at, inside or outside the ones above (also left out of search results).
    var visionExcluded: [String] {
        didSet { defaults.set(visionExcluded, forKey: Key.visionExcluded) }
    }
    /// Screenshots, documents and charts read and described too.
    var visionScreenshots: Bool {
        didSet { defaults.set(visionScreenshots, forKey: Key.visionScreenshots) }
    }
    /// Keeps working on battery (off: only plugged in).
    var visionOnBattery: Bool {
        didSet { defaults.set(visionOnBattery, forKey: Key.visionOnBattery) }
    }

    static var defaultVisionFolders: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var folders = ["Desktop", "Downloads", "Documents", "Pictures"].map { home + "/" + $0 }
        if let shots = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let path = (shots as NSString).expandingTildeInPath
            if !folders.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { folders.append(path) }
        }
        return folders
    }

    /// What `SearchIndex` works from, read on the main actor.
    var visionOptions: VisionOptions {
        VisionOptions(photos: searchPhotos, brain: ollamaModel, describe: visionDescribe, pausedUntil: visionPausedUntil,
                      folders: visionFolders, excluded: visionExcluded, screenshots: visionScreenshots, onBattery: visionOnBattery)
    }

    /// Smart search also reads the Photos library (`SearchIndex`): off until the user turns it on.
    var searchPhotos: Bool {
        didSet { defaults.set(searchPhotos, forKey: Key.searchPhotos) }
    }

    /// Morning cards (`MorningBrief`): off until the user turns them on (they read Reminders and Calendar).
    var morningCards: Bool {
        didSet { defaults.set(morningCards, forKey: Key.morningCards) }
    }

    /// When the morning cards last appeared, so they come once a day.
    var morningCardsShown: Date? {
        get { defaults.object(forKey: Key.morningCardsShown) as? Date }
        set { defaults.set(newValue, forKey: Key.morningCardsShown) }
    }

    /// A hello by the cursor whenever the Mac wakes or the user unlocks it.
    var greetings: Bool {
        didSet { defaults.set(greetings, forKey: Key.greetings) }
    }
    /// The microphone ClickBait listens through (a CoreAudio UID); nil: the system default.
    var microphoneUID: String? {
        didSet { defaults.set(microphoneUID, forKey: Microphones.defaultsKey) }
    }
    var notchVolumeHUD: Bool {
        didSet { defaults.set(notchVolumeHUD, forKey: Key.notchVolumeHUD) }
    }
    var notchBrightnessHUD: Bool {
        didSet { defaults.set(notchBrightnessHUD, forKey: Key.notchBrightnessHUD) }
    }

    /// Spotify's album covers in the notch are downloaded from its artwork link: always (true),
    /// or only with Internet Mode on (false, the default). Apple Music's come from the Mac.
    var spotifyArtworkAlways: Bool {
        didSet { defaults.set(spotifyArtworkAlways, forKey: Key.spotifyArtworkAlways) }
    }

    /// The playing YouTube video's thumbnail even with Internet Mode off (only the image, from
    /// YouTube's image server), like Spotify's covers.
    var youtubeThumbnailsAlways: Bool {
        didSet { defaults.set(youtubeThumbnailsAlways, forKey: Key.youtubeThumbnailsAlways) }
    }

    /// The notch panel's quick note: on this Mac only.
    var notchNote: String {
        didSet { defaults.set(notchNote, forKey: Key.notchNote) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        blocklist = Self.load(AppBlocklist.self, from: defaults, forKey: Key.blocklist) ?? .defaults
        keepDebugCaptures = defaults.bool(forKey: Key.keepDebugCaptures)
        speechModel = defaults.string(forKey: Key.speechModel).flatMap(SpeechModel.init(rawValue:)) ?? .default
        fillerWords = defaults.string(forKey: Key.fillerWords) ?? ""
        // A new install starts on the brain that suits this Mac; a chosen model is kept.
        ollamaModel = Self.nonEmpty(defaults.string(forKey: Key.ollamaModel)) ?? Brain.recommended(macMemoryGB: MachineFacts.memoryGB).model
        ollamaFastModel = Self.nonEmpty(defaults.string(forKey: Key.ollamaFastModel)) ?? OllamaProvider.defaultFastModel
        geminiInternetAnswers = defaults.bool(forKey: Key.geminiInternetAnswers)
        speakAnswers = defaults.object(forKey: Key.speakAnswers) as? Bool ?? true
        voiceIdentifier = defaults.string(forKey: Key.voiceIdentifier)
        speechRate = defaults.object(forKey: Key.speechRate) as? Double ?? Self.defaultSpeechRate
        commandsEnabled = defaults.object(forKey: Key.commandsEnabled) as? Bool ?? true
        allowedShortcuts = defaults.stringArray(forKey: Key.allowedShortcuts) ?? []
        notchPanelEnabled = defaults.object(forKey: Key.notchPanel) as? Bool ?? true
        ignoreNotchInCaptures = defaults.object(forKey: Key.ignoreNotchInCaptures) as? Bool ?? true
        notchNote = defaults.string(forKey: Key.notchNote) ?? ""
        notchVolumeHUD = defaults.object(forKey: Key.notchVolumeHUD) as? Bool ?? true
        notchBrightnessHUD = defaults.object(forKey: Key.notchBrightnessHUD) as? Bool ?? true
        soundCues = defaults.object(forKey: Key.soundCues) as? Bool ?? true
        agentNotices = defaults.bool(forKey: Key.agentNotices)
        agentNoticesAsked = defaults.bool(forKey: Key.agentNoticesAsked)
        healthAlerts = defaults.object(forKey: Key.healthAlerts) as? Bool ?? true
        windowSwitcher = defaults.object(forKey: Key.windowSwitcher) as? Bool ?? true
        greetings = defaults.object(forKey: Key.greetings) as? Bool ?? true
        microphoneUID = defaults.string(forKey: Microphones.defaultsKey)
        morningCards = defaults.bool(forKey: Key.morningCards)
        searchPhotos = defaults.bool(forKey: Key.searchPhotos)
        visionDescribe = defaults.object(forKey: Key.visionDescribe) as? Bool ?? true
        visionPausedUntil = defaults.object(forKey: Key.visionPausedUntil) as? Date
        visionFolders = defaults.stringArray(forKey: Key.visionFolders) ?? Self.defaultVisionFolders
        visionExcluded = defaults.stringArray(forKey: Key.visionExcluded) ?? []
        visionScreenshots = defaults.object(forKey: Key.visionScreenshots) as? Bool ?? true
        visionOnBattery = defaults.object(forKey: Key.visionOnBattery) as? Bool ?? false
        // Off unless chosen: covers come from Spotify's servers, so only with Internet Mode
        // (user's rule, 2026-10-23, keeping "nothing leaves your Mac").
        spotifyArtworkAlways = defaults.object(forKey: Key.spotifyArtworkAlways) as? Bool ?? false
        youtubeThumbnailsAlways = defaults.object(forKey: Key.youtubeThumbnailsAlways) as? Bool ?? false
        LegacyCloudSettings.remove(from: defaults)
    }

    /// Local Ollama default. Gemini is selected separately and only for opted-in Internet Mode answers.
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
