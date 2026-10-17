import AppKit
import ClickBaitCore
import EventKit
import IOKit.ps
import SwiftUI

// What the notch panel shows, read on this Mac. Nothing here polls: the players post when
// they change, the calendar is read when the panel opens, the battery when it's drawn.

// MARK: - Music

/// Music or Spotify: what's playing (from the notifications they post on every change, and one
/// Apple Events read when the panel opens), play/pause/next/previous and seeking (macOS asks
/// once per player), and the artwork — Music's from the Mac, Spotify's downloaded from its
/// own artwork link (always, or only with Internet Mode: `AppSettings.spotifyArtworkAlways`).
/// Never launches a player that isn't running.
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
    /// The artwork's colour, for the artist's name, the progress bar and the visualizer.
    private(set) var tint: NSColor?
    private(set) var error: String?

    /// Whether Spotify's artwork may be downloaded now.
    @ObservationIgnored var spotifyArtworkAllowed: () -> Bool = { true }
    /// Playing started or stopped, or the track changed (the notch's music wings follow it).
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var artworkKey: String?
    @ObservationIgnored private var spotifyCovers: [String: NSImage] = [:]

    var hasTrack: Bool { player != nil && !title.isEmpty }

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
        if Self.running.first != nil { refresh() }
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

    /// Players running now, Music first.
    static var running: [Player] {
        Player.allCases.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.rawValue).isEmpty }
    }

    /// Where playback is now (moves on by itself while playing; no polling).
    func currentPosition(at now: Date = .now) -> Double {
        TrackTime.now(reported: position, at: positionAt, playing: isPlaying, duration: duration, now: now)
    }

    private func update(_ player: Player, name: String?, artist: String?, state: String?, duration: Double?, position: Double?) {
        self.player = player
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
        title = ""
        artist = ""
        isPlaying = false
        artwork = nil
        tint = nil
        artworkKey = nil
        onChange?()
    }

    /// One read of the player's state, track, position and duration (when the panel opens or the
    /// track changes); the artwork with it.
    func refresh() {
        guard let player = player ?? Self.running.first else { return }
        self.player = player
        let script = player == .music ? """
            tell application id "com.apple.Music"
                if it is running then
                    set out to (player state as text)
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
                    set out to (player state as text)
                    try
                        set t to current track
                        set out to out & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (player position as text) & linefeed & ((duration of t) / 1000 as text) & linefeed & (artwork url of t)
                    end try
                    return out
                end if
            end tell
            """
        Task {
            do {
                let lines = (try await AppleScriptRunner.run(script, app: player.name) ?? "").components(separatedBy: "\n")
                let number = { (i: Int) in lines.count > i ? Double(lines[i].replacingOccurrences(of: ",", with: ".")) : nil }
                isPlaying = lines.first == "playing"
                if lines.count >= 5 {
                    title = lines[1]
                    artist = lines[2]
                    position = number(3) ?? position
                    positionAt = .now
                    duration = number(4) ?? duration
                }
                error = nil
                loadArtwork(player, url: lines.count >= 6 ? lines[5] : nil)
                onChange?()
            } catch {
                self.error = "Allow ClickBait to control \(player.name) in System Settings → Privacy & Security → Automation."
                onChange?()
            }
        }
    }

    func send(_ command: String) {
        guard let player = player ?? Self.running.first else { return }
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

    /// The progress bar dragged to `seconds`.
    func seek(to seconds: Double) {
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
                setArtwork(nil, for: key)
                return
            }
            if let cached = spotifyCovers[url] { setArtwork(cached, for: key); return }
            Task {
                var request = URLRequest(url: link, timeoutInterval: 4)
                request.setValue("ClickBait (notch artwork)", forHTTPHeaderField: "User-Agent")
                let data = try? await URLSession(configuration: .ephemeral).data(for: request).0
                let image = data.flatMap(NSImage.init(data:))
                if let image {
                    if spotifyCovers.count > 12 { spotifyCovers.removeAll() }
                    spotifyCovers[url] = image
                }
                setArtwork(image, for: key)
            }
        }
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

// MARK: - Calendar

/// Events and reminders for the date selected in the notch calendar. Reads EventKit data only
/// after the user grants access, and drops results from earlier date requests.
@MainActor @Observable
final class CalendarSource {
    struct Event: Identifiable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        let color: Color
    }

    struct Reminder: Identifiable {
        let id: String
        let title: String
        let dueDate: Date?
        let hasDueTime: Bool
    }

    private(set) var events: [Event] = []
    private(set) var reminders: [Reminder] = []
    private(set) var eventsAllowed = false
    private(set) var remindersAllowed = false
    private(set) var permissionDenied = false
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var selectedDate = Date()
    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var requests = CalendarRequestSequence()

    func refresh() {
        refresh(for: selectedDate)
    }

    func refresh(for date: Date) {
        selectedDate = date
        let request = requests.next()
        events = []
        reminders = []
        error = nil
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            isLoading = false
            error = "Couldn't read this date."
            return
        }

        let eventStatus = EKEventStore.authorizationStatus(for: .event)
        let reminderStatus = EKEventStore.authorizationStatus(for: .reminder)
        eventsAllowed = eventStatus == .fullAccess
        remindersAllowed = reminderStatus == .fullAccess
        permissionDenied = [eventStatus, reminderStatus].contains { $0 == .denied || $0 == .restricted }
        guard eventsAllowed || remindersAllowed else {
            isLoading = false
            return
        }
        isLoading = true

        if eventsAllowed {
            events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
                .filter { $0.startDate < end && $0.endDate > start }
                .sorted { $0.startDate < $1.startDate }
                .map { Event(id: $0.eventIdentifier ?? UUID().uuidString, title: $0.title ?? "Event",
                             start: $0.startDate, end: $0.endDate, isAllDay: $0.isAllDay,
                             color: Color(nsColor: $0.calendar.color ?? .systemBlue)) }
        }

        guard remindersAllowed else { isLoading = false; return }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let target = calendar.startOfDay(for: date)
        store.fetchReminders(matching: predicate) { [weak self] results in
            Task { @MainActor in
                guard let self, self.requests.isCurrent(request) else { return }
                let reminders = (results ?? []).compactMap { reminder -> Reminder? in
                    let components = reminder.dueDateComponents
                    let dueDate = components.flatMap { calendar.date(from: $0) }
                    if let dueDate, !calendar.isDate(dueDate, inSameDayAs: target) { return nil }
                    let hasDueTime = components?.hour != nil || components?.minute != nil
                    return Reminder(id: reminder.calendarItemIdentifier, title: reminder.title ?? "Reminder",
                                    dueDate: dueDate, hasDueTime: hasDueTime)
                }
                self.reminders = reminders.sorted {
                    switch ($0.dueDate, $1.dueDate) {
                    case let (left?, right?): left < right
                    case (_?, nil): true
                    case (nil, _?): false
                    case (nil, nil): $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                    }
                }
                self.isLoading = false
            }
        }
    }

    func requestAccess() {
        if permissionDenied {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
            return
        }
        Task {
            do {
                _ = try await store.requestFullAccessToEvents()
                _ = try await store.requestFullAccessToReminders()
                refresh()
            } catch {
                self.error = "Couldn't request Calendar or Reminders access. Check System Settings → Privacy & Security."
                self.isLoading = false
            }
        }
    }
}

// MARK: - Shelf

/// Files parked for a moment: dropped on the shelf, dragged out to anywhere, clicked to show in
/// Finder. Only references, for this session; nothing is copied, moved or deleted.
@MainActor @Observable
final class ShelfStore {
    private(set) var files: [URL] = []
    private(set) var selectedFiles: Set<URL> = []

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

// MARK: - Battery

enum Battery {
    /// Charge and charging, from the power sources on this Mac; nil without a battery.
    static func read() -> (level: Double, charging: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return (Double(current) / Double(max), description[kIOPSIsChargingKey] as? Bool ?? false)
        }
        return nil
    }
}
