import AppKit
import ClickBaitCore
import SwiftUI

// What the notch panel shows, read on this Mac. Nothing here polls: the players post when
// they change.

// MARK: - Music

/// Music or Spotify: what's playing (from the notifications they post on every change, and one
/// Apple Events read when the panel opens), play/pause/next/previous, seeking, shuffle, repeat
/// and the player's volume (macOS asks
/// once per player), and the artwork — Music's from the Mac, Spotify's downloaded from its
/// own artwork link (always, or only with Internet Mode: `AppSettings.spotifyArtworkAlways`).
/// Or a YouTube video open in Chrome or Safari (`YouTubeVideo`), whichever plays (`NowPlaying`): its
/// tab's title, its thumbnail only with Internet Mode on, play/pause and next/previous as the
/// media keys; playing when its browser sends sound out (`AudioActivity`).
/// Never launches a player or browser that isn't running.
@MainActor @Observable
final class MusicBridge {
    enum Player: String, CaseIterable {
        case music = "com.apple.Music"
        case spotify = "com.spotify.client"

        var name: String { self == .music ? "Music" : "Spotify" }
        var notification: String { self == .music ? "com.apple.Music.playerInfo" : "com.spotify.client.PlaybackStateChanged" }
    }

    private(set) var player: Player?
    private(set) var title = ""
    private(set) var artist = ""
    private(set) var isPlaying = false
    private(set) var duration = 0.0
    private(set) var position = 0.0
    private(set) var positionAt = Date()
    private(set) var artwork: NSImage?
    private(set) var shuffling = false
    private(set) var repeating = false
    /// The player's own volume, 0–100.
    private(set) var volume = 50
    /// The artwork's colour, for the artist's name, the progress bar and the visualizer.
    private(set) var tint: NSColor?
    private(set) var error: String?
    /// The YouTube tab shown when neither player has a track.
    private(set) var youtubeTab: BrowserTab?
    /// The source is sending sound out right now (`AudioActivity`): the bars move only then
    /// (user's rule, 2026-10-23: "only move when there is actually music playing").
    private(set) var soundOut = false
    /// The browser lets ClickBait run JavaScript in the video's tab (its "Allow JavaScript from
    /// Apple Events" switch): true, false (switched off), nil (not tried yet).
    private(set) var youtubeScripting: Bool?
    /// The last thing that was really playing ("com.apple.Music", "youtube|<tab>"): when
    /// nothing plays, only it may stay on the card (paused); anything else old shows the bean.
    /// ✕ forgets it (user's rules, 2026-10-24).
    @ObservationIgnored private var lastPlayed: String?

    /// Whether Spotify's artwork may be downloaded now.
    @ObservationIgnored var spotifyArtworkAllowed: () -> Bool = { false }
    /// Whether a YouTube thumbnail may be downloaded now (Internet Mode on).
    @ObservationIgnored var youtubeArtworkAllowed: () -> Bool = { false }
    /// Playing started or stopped, or the track changed (the notch's music wings follow it).
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var artworkKey: String?
    /// An app started or stopped sending sound: what's playing may have moved.
    @ObservationIgnored private var audio: AudioActivity?
    @ObservationIgnored private var audibleBrowsers: Set<String> = []

    var hasTrack: Bool { (player != nil || youtubeTab != nil) && !title.isEmpty }
    /// What the card opens: the player, or YouTube's tab.
    var sourceName: String? { player?.name ?? (youtubeTab == nil ? nil : "YouTube") }

    init() {
        let center = DistributedNotificationCenter.default()
        for player in Player.allCases {
            observers.append(center.addObserver(forName: Notification.Name(player.notification), object: nil, queue: .main) { [weak self] note in
                let info = note.userInfo ?? [:]
                // Plain values across, not the notification's dictionary.
                let name = info["Name"] as? String, artist = info["Artist"] as? String, state = info["Player State"] as? String
                let total = (info["Total Time"] as? Double).map { $0 / 1000 } ?? (info["Duration"] as? Double).map { $0 / 1000 }
                let at = info["Playback Position"] as? Double
                MainActor.assumeIsolated {
                    self?.update(player, name: name, artist: artist, state: state, duration: total, position: at)
                }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                                            object: nil, queue: .main) { [weak self] note in
            let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { if bundle == self?.player?.rawValue { self?.clear() } }
        })
        audio = AudioActivity { [weak self] in
            let playing = AudioActivity.playingBundleIDs()
            self?.checkSound(playing)
            // Only a browser starting or stopping sound (Music and Spotify post their own news).
            let browsers = playing.filter { id in BrowserTab.Browser.allCases.contains { id.hasPrefix($0.rawValue) } }
            guard let self, browsers != audibleBrowsers else { return }
            audibleBrowsers = browsers
            refresh()
        }
        refresh()
    }

    #if DEBUG
    /// For the notch render (`CLICKBAIT_TEST_NOTCH_RENDER`): a track without playing anything.
    func debugFake(title: String, artist: String, duration: Double, position: Double, artwork: NSImage) {
        player = .spotify
        self.title = title
        self.artist = artist
        self.duration = duration
        self.position = position
        positionAt = .now
        isPlaying = true
        self.artwork = artwork
        tint = Self.averageColor(artwork)
    }

    #endif

    /// Brings the player forward (Music when none has played yet), or YouTube's tab.
    func openPlayer() {
        guard let tab = youtubeTab, player == nil else { open(player ?? .music); return }
        switch tab.browser {
        case .chrome:
            // Whichever Chrome process has the tab (a hidden one can share the bundle id).
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: tab.browser.rawValue)
            where ChromeTabs.select(tab, pid: app.processIdentifier) { break }
        case .safari:
            Task { _ = try? await AppleScriptRunner.run(tab.safariReturnScript, app: tab.browser.name) }
        }
    }

    /// YouTube has no app: its site in the default browser.
    static func openYouTube() {
        if let url = URL(string: "https://www.youtube.com") { NSWorkspace.shared.open(url) }
    }

    func open(_ player: Player) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.rawValue) {
            NSWorkspace.shared.open(url)
        }
    }

    #if DEBUG
    /// For the notch render: nothing playing.
    func debugClear() {
        player = nil
        title = ""
        isPlaying = false
        artwork = nil
    }
    #endif

    /// Players running now, Music first.
    static var running: [Player] {
        Player.allCases.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.rawValue).isEmpty }
    }

    /// Where playback is now (moves on by itself while playing; no polling).
    func currentPosition(at now: Date = .now) -> Double {
        TrackTime.now(reported: position, at: positionAt, playing: isPlaying, duration: duration, now: now)
    }

    private func update(_ player: Player, name: String?, artist: String?, state: String?, duration: Double?, position: Double?) {
        if state == "Playing" { lastPlayed = player.rawValue } else if lastPlayed != player.rawValue { return }  // not the one playing last
        // A video is shown and this isn't "now playing": let `refresh` weigh them.
        if youtubeTab != nil, state != "Playing" { refresh(); return }
        self.player = player
        youtubeTab = nil
        let changed = name != nil && name != title
        if let name { title = name }
        if let artist { self.artist = artist }
        if let duration { self.duration = duration }
        if let state {
            isPlaying = state == "Playing"
            if state == "Stopped" { clear(); return }
        }
        if let position { self.position = position; positionAt = .now }
        // Music doesn't say where it is: ask, along with the artwork, when the track changes.
        if changed || position == nil { refresh() } else { onChange?() }
    }

    private func clear() {
        player = nil
        youtubeTab = nil
        title = ""
        artist = ""
        isPlaying = false
        artwork = nil
        tint = nil
        artworkKey = nil
        onChange?()
    }

    /// One read of what's playing (when the panel opens, a track changes, or an app starts or
    /// stops sending sound): Music or Spotify, and a YouTube video in a browser, whichever
    /// plays (`NowPlaying.pick`); the artwork with it.
    func refresh() {
        let candidate = player ?? Self.running.first
        Task {
            var lines: [String]?
            if let candidate {
                do {
                    lines = (try await AppleScriptRunner.run(Self.stateScript(candidate), app: candidate.name) ?? "").components(separatedBy: "\n")
                    error = nil
                } catch {
                    self.error = "Allow ClickBait to control \(candidate.name) in System Settings → Privacy & Security → Automation."
                }
            }
            let video = await youtubeVideo()
            let audible = AudioActivity.playingBundleIDs()
            // The tab's own word when the browser allows scripting; else its browser's sound.
            let videoPlaying = video.map { found in found.playing ?? audible.contains { $0.hasPrefix(found.tab.browser.rawValue) } }
            var hasTrack = (lines?.count ?? 0) >= 8
            let playerPlaying = hasTrack && lines?.first == "playing"
            var videoState = videoPlaying
            if playerPlaying, let candidate { lastPlayed = candidate.rawValue }
            if videoPlaying == true, let video { lastPlayed = "youtube|\(video.tab.tab)" }
            // Paused: only what was last really playing stays (an old paused track elsewhere
            // took the card, and play then started that instead of the video).
            if hasTrack, !playerPlaying, lastPlayed != candidate?.rawValue { hasTrack = false }
            if let video, videoState == false, lastPlayed != "youtube|\(video.tab.tab)" { videoState = nil }
            let source = NowPlaying.pick(player: hasTrack ? playerPlaying : nil, youtube: videoState,
                                         showingYouTube: youtubeTab != nil)
            Log.app.notice("Notch music: \(String(describing: source), privacy: .public) (YouTube \(videoPlaying.map { $0 ? "playing" : "paused" } ?? "none", privacy: .public))")
            switch source {
            case .player:
                if let candidate, let lines { show(candidate, lines) }
            case .youtube:
                if let video, let videoState { show(video.tab, video.video, playing: videoState) }
            case .none:
                if hasTrack || youtubeTab != nil || player != nil { clear() }
            }
            checkSound(audible)
            onChange?()
        }
    }

    private func checkSound(_ playing: Set<String>) {
        let source = player?.rawValue ?? youtubeTab?.browser.rawValue
        let now = source.map { source in playing.contains { $0.hasPrefix(source) } } ?? false
        if soundOut != now { soundOut = now }
    }

    /// state, shuffle, repeat, volume; then the track: name, artist, position, duration (, artwork link).
    private func show(_ player: Player, _ lines: [String]) {
        let number = { (i: Int) in lines.count > i ? Double(lines[i].replacingOccurrences(of: ",", with: ".")) : nil }
        self.player = player
        youtubeTab = nil
        isPlaying = lines.first == "playing"
        shuffling = lines[1] == "true"
        repeating = !["off", "false"].contains(lines[2])
        volume = number(3).map { Int($0) } ?? volume
        title = lines[4]
        artist = lines[5]
        position = number(6) ?? position
        positionAt = .now
        duration = number(7) ?? duration
        loadArtwork(player, url: lines.count >= 9 ? lines[8] : nil)
    }

    private func show(_ tab: BrowserTab, _ video: YouTubeVideo, playing: Bool) {
        let sameVideo = youtubeTab == tab && title == video.title
        player = nil
        youtubeTab = tab
        title = video.title
        artist = "YouTube"
        isPlaying = playing
        if !sameVideo || youtubeScripting != true { (duration, position, positionAt) = (0, 0, .now) }
        Task { await readYouTube() }
        let key = "youtube|\(video.id)"
        // Also once Internet Mode is switched on while the video was showing without its picture.
        if key != artworkKey || (artwork == nil && youtubeArtworkAllowed()) {
            artworkKey = key
            if youtubeArtworkAllowed() { download(video.thumbnail, for: key) } else { setArtwork(CoverCache.image(for: key), for: key) }
        }
    }

    /// Runs JavaScript in the shown video's tab (or `tab`); nil when the browser refuses or the tab's gone.
    private func runYouTube(_ javascript: String, in other: BrowserTab? = nil) async -> String? {
        guard let tab = other ?? youtubeTab else { return nil }
        if tab.browser == .chrome {
            // In the Chrome process that owns the tab (see `ChromeTabs.execute`).
            let pids = NSRunningApplication.runningApplications(withBundleIdentifier: tab.browser.rawValue).map(\.processIdentifier)
            let output = await Task.detached(priority: .userInitiated) {
                pids.lazy.compactMap { ChromeTabs.execute(javascript, tabID: tab.tab, pid: $0) }.first
            }.value
            if output != nil { youtubeScripting = true }
            return output
        }
        do {
            let output = try await AppleScriptRunner.run(YouTubeControl.appleScript(javascript, in: tab), app: tab.browser.name)
            youtubeScripting = true
            return output == "gone" ? nil : output
        } catch {
            if YouTubeControl.isTurnedOff(error.localizedDescription) { youtubeScripting = false }
            Log.app.notice("Notch music: YouTube tab script failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The video's real state, time and channel, when the browser allows it.
    private func readYouTube() async {
        guard let output = await runYouTube(YouTubeControl.readState), let state = YouTubeControl.parse(output),
              youtubeTab != nil, player == nil else { return }
        isPlaying = state.playing
        (position, duration, positionAt) = (state.position, state.duration, .now)
        if !state.channel.isEmpty { artist = state.channel }
        onChange?()
    }

    private static func stateScript(_ player: Player) -> String {
        player == .music ? """
            tell application id "com.apple.Music"
                if it is running then
                    set out to (player state as text) & linefeed & (shuffle enabled as text) & linefeed & (song repeat as text) & linefeed & (sound volume as text)
                    try
                        set t to current track
                        set out to out & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (player position as text) & linefeed & (duration of t as text)
                    end try
                    return out
                end if
            end tell
            """ : """
            tell application id "com.spotify.client"
                if it is running then
                    set out to (player state as text) & linefeed & (shuffling as text) & linefeed & (repeating as text) & linefeed & (sound volume as text)
                    try
                        set t to current track
                        set out to out & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (player position as text) & linefeed & ((duration of t) / 1000 as text) & linefeed & (artwork url of t)
                    end try
                    return out
                end if
            end tell
            """
    }

    func send(_ command: String) {
        if youtubeTab != nil, player == nil {
            let script: String? = switch command {
            case "playpause": YouTubeControl.playPause
            case "next track": YouTubeControl.next
            case "previous track": YouTubeControl.previous
            default: nil
            }
            guard let script else { return }
            Task {
                // In the video's own tab when the browser allows it; else the media keys, which
                // reach only whatever macOS calls "Now Playing".
                if await runYouTube(script) == "ok" {
                    Log.app.notice("Notch music: \(command, privacy: .public) → YouTube tab")
                    if command == "playpause" { isPlaying.toggle(); position = currentPosition(); positionAt = .now }
                    try? await Task.sleep(for: .milliseconds(command == "playpause" ? 150 : 900))
                    await readYouTube()
                } else {
                    Log.app.notice("Notch music: \(command, privacy: .public) → media key (tab scripting: \(String(describing: self.youtubeScripting), privacy: .public))")
                    switch command {
                    case "playpause": MediaKeys.press(.playPause)
                    case "next track": MediaKeys.press(.next)
                    default: MediaKeys.press(.previous)
                    }
                }
            }
            return
        }
        guard let player = player ?? Self.running.first else { Log.app.notice("Notch music: \(command, privacy: .public) → no player"); return }
        Log.app.notice("Notch music: \(command, privacy: .public) → \(player.name, privacy: .public)")
        Task {
            do {
                try await AppleScriptRunner.run("tell application id \"\(player.rawValue)\" to if it is running then \(command)", app: player.name)
                if command == "playpause" {
                    position = currentPosition()
                    positionAt = .now
                    isPlaying.toggle()
                }
                error = nil
            } catch {
                self.error = "Allow ClickBait to control \(player.name) in System Settings → Privacy & Security → Automation."
            }
        }
    }

    /// The player card's ✕ (user's rule, 2026-10-23: "X should STOP the music"): Music stops
    /// (no paused track is left), Spotify and YouTube pause; the home card goes back to space.
    func stop() {
        if let tab = youtubeTab, player == nil {
            Task { _ = await runYouTube(YouTubeControl.pause, in: tab) }
        } else if let player {
            send(player == .music ? "stop" : "pause")
        }
        lastPlayed = nil
        // Exit, not pause (user's rule, 2026-10-24): the music leaves the notch, with no
        // resume chip, until something plays.
        clear()
    }

    func setShuffling(_ on: Bool) {
        shuffling = on
        send(player == .music ? "set shuffle enabled to \(on)" : "set shuffling to \(on)")
    }

    /// Repeat on repeats the whole list (Music's "all"), as Spotify does.
    func setRepeating(_ on: Bool) {
        repeating = on
        send(player == .music ? "set song repeat to \(on ? "all" : "off")" : "set repeating to \(on)")
    }

    /// The player's own volume (not the Mac's), 0–100.
    func setVolume(_ level: Int) {
        volume = min(max(level, 0), 100)
        send("set sound volume to \(volume)")
    }

    /// The progress bar dragged to `seconds`.
    func seek(to seconds: Double) {
        if youtubeTab != nil, player == nil {
            position = seconds
            positionAt = .now
            Task { _ = await runYouTube(YouTubeControl.seek(to: seconds)) }
            return
        }
        guard let player else { return }
        position = seconds
        positionAt = .now
        send("set player position to \(String(format: "%.1f", seconds))")
        _ = player
    }

    private func loadArtwork(_ player: Player, url: String?) {
        let key = "\(player.rawValue)|\(title)|\(artist)"
        guard key != artworkKey else { return }
        artworkKey = key
        switch player {
        case .music:
            Task {
                let data = await Task.detached(priority: .utility) { () -> Data? in
                    var error: NSDictionary?
                    let script = "tell application id \"com.apple.Music\" to if it is running then get raw data of artwork 1 of current track"
                    return NSAppleScript(source: script)?.executeAndReturnError(&error).data
                }.value
                setArtwork(data.flatMap(NSImage.init(data:)), for: key)
            }
        case .spotify:
            guard let url, let link = URL(string: url), link.scheme == "https", spotifyArtworkAllowed() else {
                setArtwork(CoverCache.image(for: key), for: key)  // seen before with Internet Mode on
                return
            }
            download(link, for: key)
        }
    }

    /// A cover from the web (Spotify's link, YouTube's thumbnail): the saved copy when this
    /// track was seen before (no download), else downloaded and saved for Internet Mode off.
    private func download(_ link: URL, for key: String) {
        if let saved = CoverCache.image(for: key) { setArtwork(saved, for: key); return }
        Task {
            let request = URLRequest(url: link, timeoutInterval: 4)
            let data = try? await URLSession(configuration: .ephemeral).data(for: request).0
            let image = data.flatMap(NSImage.init(data:))
            if let data, image != nil { CoverCache.save(data, for: key) }
            setArtwork(image, for: key)
        }
    }

    /// The YouTube video to show among the running browsers' tabs: with the browser's
    /// JavaScript switch on, the one actually playing (each tab asked, up to 8; with dozens
    /// of tabs the first one found was often not it); else the front-most one, showing tabs
    /// first. `playing` is the tab's own answer, nil when it couldn't be asked. Reads only
    /// browsers already running (macOS asks once per browser).
    private func youtubeVideo() async -> (tab: BrowserTab, video: YouTubeVideo, playing: Bool?)? {
        var tabs: [BrowserTab] = []
        for browser in BrowserTab.Browser.allCases {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: browser.rawValue)
            guard !apps.isEmpty else { continue }
            switch browser {
            case .chrome:
                // Every Chrome: a hidden automated one (a test runner's) can share the bundle id.
                for pid in apps.map(\.processIdentifier) {
                    tabs += await Task.detached(priority: .utility) { ChromeTabs.readAll(pid: pid) }.value
                }
            case .safari:
                let output = try? await AppleScriptRunner.run(BrowserTab.safariAllTabsScript, app: browser.name)
                tabs += BrowserTab.parse(output ?? "", browser: browser)
            }
        }
        let videos = tabs.compactMap { tab in YouTubeVideo(url: tab.url, tabTitle: tab.title).map { (tab: tab, video: $0) } }
        guard let first = videos.first else {
            Log.app.notice("Notch music: \(tabs.count, privacy: .public) browser tab(s) read, YouTube not open")
            return nil
        }
        var asked = false
        if youtubeScripting != false {
            for candidate in videos.prefix(8) {
                let output = await runYouTube(YouTubeControl.readState, in: candidate.tab)
                guard let output, let state = YouTubeControl.parse(output) else {
                    Log.app.notice("Notch music: YouTube tab gave \(output.map { "\"\($0.prefix(60))\"" } ?? "nothing", privacy: .public)")
                    continue
                }
                asked = true
                if state.playing {
                    Log.app.notice("Notch music: \(videos.count, privacy: .public) YouTube tab(s), one playing")
                    return (candidate.tab, candidate.video, true)
                }
            }
        }
        Log.app.notice("Notch music: \(videos.count, privacy: .public) YouTube tab(s), none \(asked ? "playing" : "asked", privacy: .public)")
        return (first.tab, first.video, asked ? false : nil)
    }

    private func setArtwork(_ image: NSImage?, for key: String) {
        guard key == artworkKey else { return }
        artwork = image
        tint = image.flatMap(Self.averageColor)
    }

    /// The image squeezed to one pixel.
    private static func averageColor(_ image: NSImage) -> NSColor? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 4, bitsPerPixel: 32) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 1, height: 1))
        NSGraphicsContext.restoreGraphicsState()
        return rep.colorAt(x: 0, y: 0)
    }
}

// MARK: - Shelf

/// Files parked for a moment: dropped on the shelf, dragged out to anywhere, clicked to show in
/// Finder. Only references, for this session; nothing is copied, moved or deleted.
@MainActor @Observable
final class ShelfStore {
    private(set) var files: [URL] = []
    private(set) var selectedFiles: Set<URL> = []
    /// Lives as long as the shelf, so a send outlasts the notch closing behind the AirDrop window.
    let airDrop = AirDropSender()

    func add(_ urls: [URL]) {
        for url in urls where !files.contains(url) { files.append(url) }
        if files.count > 12 { files.removeFirst(files.count - 12) }
        selectedFiles.formIntersection(files)
    }

    func remove(_ url: URL) {
        files.removeAll { $0 == url }
        selectedFiles.remove(url)
    }

    func toggleSelection(_ url: URL) {
        guard files.contains(url) else { return }
        if !selectedFiles.insert(url).inserted { selectedFiles.remove(url) }
    }

    func selectAll() { selectedFiles = Set(files) }
    func clearSelection() { selectedFiles.removeAll() }
}

// MARK: - AirDrop

/// The shelf's AirDrop pad: hands files straight to macOS's AirDrop window, which lists the
/// people and devices nearby and does the sending. ClickBait never turns AirDrop or Bluetooth
/// on; when AirDrop can't send, it says so.
@MainActor @Observable
final class AirDropSender: NSObject, NSSharingServiceDelegate {
    enum Status: Equatable {
        case idle
        /// The AirDrop window is up, waiting for a recipient.
        case choosing(Int)
        case sent(Int)
        case failed(String)
    }

    private(set) var status: Status = .idle
    @ObservationIgnored private var service: NSSharingService?
    @ObservationIgnored private var resetTask: Task<Void, Never>?

    func send(_ urls: [URL]) {
        guard !urls.isEmpty else {
            show(.failed("Drop files here, or add some to the shelf first"))
            return
        }
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            show(.failed("AirDrop is off: turn it on in Control Center"))
            Log.app.notice("AirDrop: not available")
            return
        }
        service.delegate = self
        self.service = service
        NSApp.activate()  // ClickBait has no Dock icon: bring the AirDrop window to the front
        resetTask?.cancel()
        status = .choosing(urls.count)
        service.perform(withItems: urls)
        Log.app.notice("AirDrop: \(urls.count, privacy: .public) file(s) offered")
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        let count = items.count
        MainActor.assumeIsolated {
            show(.sent(count))
            service = nil
            Log.app.notice("AirDrop: sent")
        }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        let cancelled = (error as NSError).code == NSUserCancelledError
        MainActor.assumeIsolated {
            show(cancelled ? .idle : .failed("AirDrop didn't send: \(error.localizedDescription)"))
            service = nil
            Log.app.notice("AirDrop: \(cancelled ? "cancelled" : "failed", privacy: .public)")
        }
    }

    /// A result shows for 4 s, then the pad is back to its prompt.
    private func show(_ new: Status) {
        status = new
        resetTask?.cancel()
        guard new != .idle else { return }
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.status = .idle
        }
    }
}
