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
        guard let tab = youtubeTab, player == nil else {
            Log.app.notice("Notch cover: opening \(self.player?.name ?? "Music (nothing played yet)", privacy: .public)")
            open(player ?? .music)
            return
        }
        switch tab.browser {
        case .chrome:
            // Whichever Chrome process has the tab (a hidden one can share the bundle id).
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: tab.browser.rawValue)
            let chrome = apps.first { ChromeTabs.select(tab, pid: $0.processIdentifier) }
            Log.app.notice("Notch cover: YouTube tab in Chrome \(chrome != nil ? "selected" : "NOT found", privacy: .public) (\(apps.count, privacy: .public) Chrome process(es))")
            // Selecting the tab doesn't bring Chrome forward from a click in the notch (macOS
            // ignores an activation asked for by an app that isn't in front: user's report,
            // 2026-11-01). As "go there" does: accessibility raises it, then it's checked.
            if let chrome { bringForward(chrome) }
        case .safari:
            Task {
                let found = (try? await AppleScriptRunner.run(tab.safariReturnScript, app: tab.browser.name)) == "true"
                Log.app.notice("Notch cover: YouTube tab in Safari \(found ? "selected" : "NOT found", privacy: .public)")
            }
        }
    }

    /// Brings `app` to the front for real (onto its window's desktop), and logs whether it got there.
    private func bringForward(_ app: NSRunningApplication) {
        AXInspector.bringToFront(pid: app.processIdentifier)
        app.activate()
        Task { @MainActor in
            for _ in 0..<10 where NSWorkspace.shared.frontmostApplication != app {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if NSWorkspace.shared.frontmostApplication != app, let url = app.bundleURL {
                // Last resort: Launch Services always brings a running app forward.
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            }
            Log.app.notice("Notch cover: \(app.localizedName ?? "the app", privacy: .public) in front \(NSWorkspace.shared.frontmostApplication == app, privacy: .public)")
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
        showThumbnail(of: video)
    }

    /// The video's thumbnail (downloaded with Internet Mode on, else a saved one), or none.
    private func showThumbnail(of video: YouTubeVideo) {
        let key = "youtube|\(video.id)"
        // Also once Internet Mode is switched on while the video was showing without its picture.
        guard key != artworkKey || (artwork == nil && youtubeArtworkAllowed()) else { return }
        if key != artworkKey { showSavedCover(for: key) }
        artworkKey = key
        if youtubeArtworkAllowed() { download(video.thumbnail, for: key) } else { setArtwork(CoverCache.image(for: key), for: key) }
    }

    /// Runs JavaScript in the shown video's tab (or `tab`); nil when the browser refuses or the tab's gone.
    private func runYouTube(_ javascript: String, in other: BrowserTab? = nil) async -> String? {
        guard let tab = other ?? youtubeTab else { return nil }
        if tab.browser == .chrome {
            // In the Chrome process that owns the tab (see `ChromeTabs.execute`).
            let pids = NSRunningApplication.runningApplications(withBundleIdentifier: tab.browser.rawValue).map(\.processIdentifier)
            // Once per process, stopping at the first answer: `lazy.compactMap(...).first` ran the
            // script twice (a play/pause undid itself) and crashed when the second run had nothing.
            let output = await Task.detached(priority: .userInitiated) { () -> String? in
                for pid in pids {
                    if let output = ChromeTabs.execute(javascript, tabID: tab.tab, pid: pid) { return output }
                }
                return nil
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
        // Skipped, or YouTube moved on by itself: the video, its title and thumbnail from the
        // page itself. Chrome's tab title lags a skip by about a second, and reading it marked
        // the new video as shown under the old name for good (user's report, 2026-11-01).
        if let url = state.url, let now = YouTubeVideo(url: url, tabTitle: state.pageTitle ?? "") {
            if "youtube|\(now.id)" != artworkKey { showThumbnail(of: now) }
            if now.title != "YouTube", now.title != title { title = now.title }
        }
        onChange?()
    }

    @ObservationIgnored private var following: Task<Void, Never>?

    /// While the notch is open: a YouTube video is checked every 2 s (one script in its tab),
    /// so a skip or autoplay shows at once. Music and Spotify tell ClickBait themselves.
    func follow(_ on: Bool) {
        following?.cancel()
        following = nil
        guard on else { return }
        following = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                if youtubeTab != nil, player == nil {
                    if youtubeScripting == false { refresh() } else { await readYouTube() }
                }
            }
        }
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
                    try? await Task.sleep(for: .milliseconds(command == "playpause" ? 150 : 600))
                    await readYouTube()
                    if command != "playpause" {
                        try? await Task.sleep(for: .milliseconds(900))  // a slow page swaps later
                        await readYouTube()
                    }
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
        showSavedCover(for: key)
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

    /// A new track: its saved cover at once, else none, instead of the last track's staying up
    /// until the new one has downloaded.
    private func showSavedCover(for key: String) {
        artwork = CoverCache.image(for: key)
        tint = artwork.flatMap(Self.averageColor)
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

    /// Renames a shelved file on disk, in its own folder, and keeps its place on the shelf and
    /// its selection. A name typed without an extension keeps the file's own; slashes and
    /// colons become dashes; an empty or unchanged name does nothing.
    @discardableResult
    func rename(_ url: URL, to typed: String) throws -> URL {
        var name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        guard !name.isEmpty, name != url.lastPathComponent, let index = files.firstIndex(of: url) else { return url }
        if (name as NSString).pathExtension.isEmpty, !url.pathExtension.isEmpty { name += "." + url.pathExtension }
        let target = url.deletingLastPathComponent().appending(path: name)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey: "\(name) already exists there"])
        }
        try FileManager.default.moveItem(at: url, to: target)
        files[index] = target
        if selectedFiles.remove(url) != nil { selectedFiles.insert(target) }
        return target
    }

    func toggleSelection(_ url: URL) {
        guard files.contains(url) else { return }
        if !selectedFiles.insert(url).inserted { selectedFiles.remove(url) }
    }

    func selectAll() { selectedFiles = Set(files) }
    /// Adds files to the selection (shelving them first), as a drop on the AirDrop pad does.
    func select(_ urls: [URL]) {
        add(urls)
        selectedFiles.formUnion(urls.filter(files.contains))
    }
    func clearSelection() { selectedFiles.removeAll() }
}

// MARK: - AirDrop

/// The shelf's AirDrop pad: hands files straight to macOS's AirDrop window, which lists the
/// people and devices nearby and does the sending. ClickBait never turns AirDrop or Bluetooth
/// on; when AirDrop can't send, it says so.
@MainActor @Observable
final class AirDropSender: NSObject, NSSharingServiceDelegate, NSSharingServicePickerDelegate {
    enum Status: Equatable {
        case idle
        /// The AirDrop window is up, waiting for a recipient.
        case choosing(Int)
        case failed(String)
    }

    /// The window the AirDrop picker belongs to (the open notch), so it opens in front of it,
    /// not wherever macOS guesses (it opened under the notch or jumped about; user's report,
    /// 2026-11-01). Set by the notch.
    @ObservationIgnored var anchor: (() -> NSWindow?)?
    /// The pad itself: the AirDrop picker drops down from it, just below the notch, Taby-style
    /// (user's ask, 2026-11-01), listing the people and devices nearby. Set by the pad.
    @ObservationIgnored weak var padView: NSView?
    /// The card under the notch that AirDrop's chooser slides into.
    @ObservationIgnored private var host: NSWindow?
    @ObservationIgnored private var sheetEnded: NSObjectProtocol?
    @ObservationIgnored private var hostLabel: NSTextField?
    /// What the chooser offers now, and since when; a bigger set waiting for it to close.
    @ObservationIgnored private var offered: [URL] = []
    @ObservationIgnored private var offeredAt = Date.distantPast
    @ObservationIgnored private var queued: [URL]?
    @ObservationIgnored private var watchdog: Task<Void, Never>?

    /// What a send would hand over: real files still on disk, each once. The pad's count, its
    /// click and a drop on it all use this, so the number shown is the number sent.
    static func sendable(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return urls.filter { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) && seen.insert($0.standardizedFileURL).inserted }
    }

    private(set) var status: Status = .idle
    @ObservationIgnored private var pickerItems = 0
    @ObservationIgnored private var service: NSSharingService?
    @ObservationIgnored private var resetTask: Task<Void, Never>?

    func send(_ urls: [URL]) {
        let urls = Self.sendable(urls)
        guard !urls.isEmpty else {
            show(.failed("Drop files here, or add some to the shelf first"))
            return
        }
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            show(.failed("AirDrop is off: turn it on in Control Center"))
            Log.app.notice("AirDrop: not available")
            return
        }
        // The same set again within a second is one action firing twice (it opened two choosers).
        if urls == offered, Date().timeIntervalSince(offeredAt) < 1 { return }
        // More while the chooser is up: it closes and comes back in the same card with
        // everything (a new card per drop left an empty one; user's report, 2026-11-01).
        if let host, let sheet = host.attachedSheet {
            queued = urls
            offered = urls
            offeredAt = Date()
            hostLabel?.stringValue = Self.label(urls.count)
            host.endSheet(sheet)
            return
        }
        start(urls, with: service)
    }

    private func start(_ urls: [URL], with service: NSSharingService) {
        service.delegate = self
        self.service = service
        offered = urls
        offeredAt = Date()
        // ClickBait's own card hangs just below the notch, Taby-style, and AirDrop's chooser
        // slides down inside it as a sheet (it floated wherever macOS put it, even on the other
        // display; user's report, 2026-11-01). The device list itself is Apple's: there's no
        // public way to draw it ourselves.
        if host == nil { showHost(count: urls.count) } else { hostLabel?.stringValue = Self.label(urls.count) }
        watchHost()
        resetTask?.cancel()
        status = .choosing(urls.count)
        service.perform(withItems: urls)
        // The pad says "choose who gets…" for as long as the card is up; the card's watchdog
        // and ✕ put it back to its prompt.
        Log.app.notice("AirDrop: \(urls.count, privacy: .public) file(s) offered")
    }

    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> (any NSSharingServiceDelegate)? {
        MainActor.assumeIsolated { self }
    }

    /// Picked a device (or AirDrop), or closed the popover without one.
    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        let closed = service == nil
        MainActor.assumeIsolated {
            if closed { show(.idle) }
            Log.app.notice("AirDrop: \(closed ? "closed without sending" : "picked", privacy: .public)")
        }
    }

    /// macOS calls this when the picker closes, whether or not anyone was picked, and can't
    /// say if the files arrived (its own window shows that). So no "sent": back to the prompt.
    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        let which = ObjectIdentifier(sharingService)
        MainActor.assumeIsolated {
            guard service.map(ObjectIdentifier.init) == which, queued == nil else { return }  // a replaced chooser
            show(.idle)
            service = nil
            closeHost()
            Log.app.notice("AirDrop: the picker closed")
        }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, sourceWindowForShareItems items: [Any],
                                    sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? {
        MainActor.assumeIsolated { host ?? anchor?() }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        let cancelled = (error as NSError).code == NSUserCancelledError
        let which = ObjectIdentifier(sharingService)
        MainActor.assumeIsolated {
            guard service.map(ObjectIdentifier.init) == which, queued == nil else { return }  // a replaced chooser
            show(cancelled ? .idle : .failed("AirDrop didn't send: \(error.localizedDescription)"))
            service = nil
            closeHost()
            Log.app.notice("AirDrop: \(cancelled ? "cancelled" : "failed", privacy: .public)")
        }
    }

    /// A black card centred under the notch, a small gap below it, the way Taby hangs its
    /// panels; AirDrop's sheet attaches to its top. Closed when AirDrop reports back.
    private func showHost(count: Int) {
        closeHost()
        // Placed from the pad that was used: its window is the open notch on this display
        // (the "main" panel could be another display's; the card landed bottom left). The
        // island ends a card's padding below the pad; the card starts a small gap under it.
        let size = NSSize(width: 460, height: 340)
        let screen: NSScreen, top: CGFloat, midX: CGFloat
        if let pad = padView, let notch = pad.window, let padScreen = notch.screen {
            let padRect = notch.convertToScreen(pad.convert(pad.bounds, to: nil))
            screen = padScreen
            top = padRect.minY - 10 - 10
            midX = notch.frame.midX
        } else {
            screen = NSScreen.main ?? NSScreen.screens[0]
            top = screen.visibleFrame.maxY - 10
            midX = screen.frame.midX
        }
        let origin = NSPoint(x: min(max(midX - size.width / 2, screen.frame.minX + 8), screen.frame.maxX - size.width - 8),
                             y: max(top - size.height, screen.visibleFrame.minY))
        // A panel that never brings ClickBait forward (activating it jumped to the desktop's
        // Space, away from the app the user was in; user's report, 2026-11-01), opened on the
        // Space in front, full-screen apps included, like the notch.
        let window = HostPanel(contentRect: NSRect(origin: origin, size: size),
                               styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        window.becomesKeyOnlyIfNeeded = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { window.standardWindowButton($0)?.isHidden = true }
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        // Above the open notch, which covered it (user's report, 2026-11-02); AirDrop's sheet goes with it.
        window.level = WindowLayers.dock
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let label = NSTextField(labelWithString: Self.label(count))
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = NSColor(white: 0.62, alpha: 1)
        label.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(label)
        if let content = window.contentView {
            NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                                         label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)])
        }
        // ✕, top right: closes the chooser and the card at once (user's ask, 2026-11-01).
        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close AirDrop")!,
                             target: self, action: #selector(closeTapped))
        close.isBordered = false
        close.contentTintColor = NSColor(white: 0.55, alpha: 1)
        close.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(close)
        if let content = window.contentView {
            NSLayoutConstraint.activate([close.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
                                         close.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10)])
        }
        host = window
        hostLabel = label
        window.setFrameOrigin(origin)  // titled windows get nudged on creation: put it back
        window.makeKeyAndOrderFront(nil)
        // AirDrop's sheet gone (sent, cancelled, or nobody picked): the card goes with it,
        // even when macOS doesn't call back.
        sheetEnded = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sheetDidEnd() }
        }
    }

    @objc private func closeTapped() {
        queued = nil
        if let host, let sheet = host.attachedSheet { host.endSheet(sheet) }
        service = nil
        show(.idle)
        closeHost()
        Log.app.notice("AirDrop: closed with ✕")
    }

    /// The chooser closed: a queued, bigger set opens in the same card, else the card goes.
    private func sheetDidEnd() {
        guard let urls = queued else { return closeHost() }
        queued = nil
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else { return closeHost() }
        start(urls, with: service)
    }

    /// The card never stays empty for long: AirDrop's chooser can close (or never attach)
    /// without macOS saying so, which left a blank card up (user's report, 2026-11-01). Twice a
    /// second: no visible chooser in it for 6 s, nothing queued, and the card goes. Generous,
    /// as the ✕ badge closes it at once (a short wait closed it mid-send).
    private func watchHost() {
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            var emptySince: Date?
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, let host = self.host else { return }
                // Attached but hidden counts as gone: after Cancel it lingered, invisible.
                if host.attachedSheet?.isVisible == true || self.queued != nil { emptySince = nil; continue }
                let since = emptySince ?? Date()
                emptySince = since
                if Date().timeIntervalSince(since) >= 6 {
                    Log.app.notice("AirDrop: the chooser is gone, closing the card")
                    self.service = nil
                    self.show(.idle)
                    self.closeHost()
                    return
                }
            }
        }
    }

    private static func label(_ count: Int) -> String { count == 1 ? "airdrop · 1 file" : "airdrop · \(count) files" }

    /// Takes the keyboard for AirDrop's sheet without activating ClickBait.
    private final class HostPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private func closeHost() {
        watchdog?.cancel()
        watchdog = nil
        sheetEnded.map(NotificationCenter.default.removeObserver)
        sheetEnded = nil
        hostLabel = nil
        queued = nil
        offered = []
        host?.orderOut(nil)
        host = nil
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
