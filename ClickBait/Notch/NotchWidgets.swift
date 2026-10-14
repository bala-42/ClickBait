import AppKit
import ClickBaitCore
import AVFoundation
import Darwin
import EventKit
import IOKit.ps
import SwiftUI

/// A module in the notch panel. New ones conform and are added to `NotchController.widgets`;
/// one that can't work right now (no music app running, say) says so with `isAvailable` and
/// is left out. `expanded(_:)` and `collapsed()` start and stop any work, so nothing runs
/// while the panel is closed.
/// Where a widget sits: beside the notch in the header row, a card on the Home tab, or on
/// the Shelf tab.
enum NotchPlacement { case headerLeading, headerTrailing, card, shelf, mirror }

@MainActor
protocol NotchWidget: AnyObject {
    var id: String { get }
    var placement: NotchPlacement { get }
    var isAvailable: Bool { get }
    var view: AnyView { get }
    func expanded()
    func collapsed()
}

extension NotchWidget {
    func expanded() {}
    func collapsed() {}
}

/// The notch's look: ClickBait's theme, retro Mac OS Aqua in dark mode — the chat's own
/// materials (`AquaDark`, `AquaBody`, `AquaHeaderBar`, `AquaGel`, `AquaWell`) and Aqua's own
/// button colours (blue gel, graphite), never the state colours — on black, so it grows out
/// of the notch itself.
enum NotchStyle {
    static let title = AquaDark.textPrimary
    static let secondary = AquaDark.textSecondary
    static let tertiary = AquaDark.textTertiary
    /// Readable sizes (user's rule, 2026-10-14): body 13, secondary 12, labels ≥ 10.
    static let body = Font.system(size: 13, weight: .semibold)
    static let detail = Font.system(size: 12)
    static let label = Font.system(size: 10, weight: .bold)

    static func heading(_ text: String) -> some View {
        Text(text.uppercased()).font(label).kerning(0.6).foregroundStyle(secondary)
    }
}


/// A card under the notch: a dark Aqua window in miniature — a glossy title strip (the old
/// title bars' sheen) over a pinstriped body, a hairline round it.
struct NotchCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                CompanionTriangle(tone: .idle, pulsing: false).scaleEffect(0.5).frame(width: 9, height: 9)
                    .accessibilityHidden(true)
                NotchStyle.heading(title)
            }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(AquaHeaderBar())
            content
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background {
            ZStack {
                shape.fill(AquaDark.hex(0x16181A))
                Image(nsImage: AquaDark.pinstripes).resizable(resizingMode: .tile)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(AquaDark.border.opacity(0.8), lineWidth: 0.8))
    }
}

extension AquaPalette {
    /// The light-blue Aqua of ClickBait's card buttons (`AquaButtonStyle`, the user's choice
    /// after HeyClicky's): black text and icons on it.
    static let lightBlue = AquaPalette(stops: [AquaDark.hex(0xC7E3FF), AquaDark.hex(0x9ACBFC), AquaDark.hex(0x78B5F7)],
                                       rim: AquaDark.hex(0x4080D1), glow: AquaDark.hex(0x78B5F7))
}

/// A small round or capsule gel button (Aqua's own colours: blue for the main action and
/// what's on, graphite for the rest).
struct NotchGelButton<Label: View>: View {
    /// On (selected, the main action): light-blue Aqua with black ink; off: graphite, white ink.
    var on = false
    var size = CGSize(width: 24, height: 24)
    let action: () -> Void
    @ViewBuilder var label: Label
    @Environment(\.aquaPressed) private var pressed

    var body: some View {
        Button(action: action) {
            ZStack {
                AquaGel(palette: on ? .lightBlue : .graphite, shape: Capsule(), pressed: pressed)
                label.foregroundStyle(on ? Color.black.opacity(0.88) : .white)
                    .shadow(color: on ? .white.opacity(0.4) : .black.opacity(0.35), radius: 0.5, y: on ? 0.5 : -0.5)
            }
            .frame(width: size.width, height: size.height)
        }
        .buttonStyle(AquaPressStyle())
    }
}

// MARK: - Mode toggles

/// ClickBait's modes as quick switches: Internet 🔒/🌐 and spoken commands.
@MainActor
final class ModesWidget: NotchWidget {
    let id = "modes"
    let placement = NotchPlacement.headerLeading
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    var isAvailable: Bool { true }

    var view: AnyView {
        AnyView(ModesWidgetView(settings: settings))
    }
}

private struct ModesWidgetView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        HStack(spacing: 6) {
            NotchGelButton(on: settings.internet.isOn, size: CGSize(width: 26, height: 18),
                           action: { settings.internet.toggle() }) {
                Image(systemName: "globe").font(.system(size: 10, weight: .semibold))
            }
            .help(settings.internet.isOn ? "Internet Mode on: click to turn off" : "Internet Mode off: click to turn on")
            .accessibilityLabel("Internet Mode")
            .accessibilityValue(settings.internet.isOn ? "on" : "off")
            NotchGelButton(on: settings.commandsEnabled, size: CGSize(width: 26, height: 18),
                           action: { settings.commandsEnabled.toggle() }) {
                Image(systemName: "command").font(.system(size: 10, weight: .semibold))
            }
            .help(settings.commandsEnabled ? "Spoken commands on" : "Spoken commands off")
            .accessibilityLabel("Spoken commands")
            .accessibilityValue(settings.commandsEnabled ? "on" : "off")
        }
    }
}

// MARK: - Music

/// What Music or Spotify is playing, from the notifications they post when it changes (no
/// polling), and play/pause/next/previous through Apple Events (macOS asks once per app).
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
    private(set) var error: String?
    /// Apple Music's artwork for the track (Spotify's is online only), and its average colour
    /// for the glow.
    private(set) var artwork: NSImage?
    private(set) var artworkColor: Color?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        let center = DistributedNotificationCenter.default()
        for player in Player.allCases {
            observers.append(center.addObserver(forName: Notification.Name(player.notification), object: nil, queue: .main) { [weak self] note in
                let info = note.userInfo ?? [:]
                // Plain strings across, not the notification's dictionary.
                let name = info["Name"] as? String, artist = info["Artist"] as? String, state = info["Player State"] as? String
                MainActor.assumeIsolated { self?.update(player, name: name, artist: artist, state: state) }
            })
        }
        player = Self.running.first
    }

    /// Players running now, Music first.
    static var running: [Player] {
        Player.allCases.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.rawValue).isEmpty }
    }

    var isAvailable: Bool { !Self.running.isEmpty }

    private func update(_ player: Player, name: String?, artist: String?, state: String?) {
        self.player = player
        if let name, name != title { loadArtwork() }
        title = name ?? title
        self.artist = artist ?? self.artist
        if let state { isPlaying = state == "Playing" }
    }

    /// Asks the player for what it's playing now (when the panel opens; the notifications
    /// keep it current after that).
    func refresh() {
        guard let player = player ?? Self.running.first else { return }
        self.player = player
        Task {
            let script = """
                tell application id "\(player.rawValue)"
                    if it is running then
                        set out to (player state as text)
                        try
                            set out to out & linefeed & (name of current track) & linefeed & (artist of current track)
                        end try
                        return out
                    end if
                end tell
                """
            do {
                let lines = (try await AppleScriptRunner.run(script, app: player.name) ?? "").components(separatedBy: "\n")
                isPlaying = lines.first == "playing"
                if lines.count >= 3 { title = lines[1]; artist = lines[2] }
                error = nil
                loadArtwork()
            } catch {
                self.error = "\(error)"
            }
        }
    }

    /// The current track's artwork, read from Music off the main thread.
    func loadArtwork() {
        guard player == .music else { artwork = nil; artworkColor = nil; return }
        Task {
            let data = await Task.detached(priority: .utility) { () -> Data? in
                let script = "tell application id \"com.apple.Music\" to if it is running then get raw data of artwork 1 of current track"
                var error: NSDictionary?
                return NSAppleScript(source: script)?.executeAndReturnError(&error).data
            }.value
            let image = data.flatMap(NSImage.init(data:))
            artwork = image
            artworkColor = image.flatMap(Self.averageColor)
        }
    }

    /// The image squeezed to one pixel.
    private static func averageColor(_ image: NSImage) -> Color? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 4, bitsPerPixel: 32) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 1, height: 1))
        NSGraphicsContext.restoreGraphicsState()
        return rep.colorAt(x: 0, y: 0).map { Color(nsColor: $0) }
    }

    func send(_ command: String) {
        guard let player = player ?? Self.running.first else { return }
        Task {
            do {
                try await AppleScriptRunner.run("tell application id \"\(player.rawValue)\" to if it is running then \(command)", app: player.name)
                error = nil
                if command == "playpause" { isPlaying.toggle() }
            } catch {
                self.error = "Couldn't control \(player.name): allow it in System Settings → Privacy & Security → Automation."
            }
        }
    }
}

@MainActor
final class MusicWidget: NotchWidget {
    let id = "music"
    let placement = NotchPlacement.card
    private let bridge = MusicBridge()

    var isAvailable: Bool { bridge.isAvailable }
    func expanded() { bridge.refresh() }

    var view: AnyView {
        AnyView(NotchCard(title: bridge.player?.name ?? "Music") { MusicWidgetView(bridge: bridge) })
    }
}

private struct MusicWidgetView: View {
    let bridge: MusicBridge

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                // The artwork, glowing in its own colour (the notch apps' look); a blue gel tile
                // with a note when there's none (Spotify, nothing playing).
                ZStack {
                    if let artwork = bridge.artwork {
                        Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    } else {
                        AquaGel(palette: .lightBlue, shape: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        Image(systemName: "music.note").font(.system(size: 19, weight: .semibold)).foregroundStyle(.black.opacity(0.85))
                    }
                }
                .frame(width: 50, height: 50)
                .shadow(color: (bridge.artworkColor ?? AquaDark.hex(0x9ACBFC)).opacity(0.7), radius: 10)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bridge.title.isEmpty ? "Nothing playing" : bridge.title)
                        .font(NotchStyle.body).foregroundStyle(NotchStyle.title).lineLimit(1)
                    Text(bridge.artist.isEmpty ? bridge.player?.name ?? "" : bridge.artist)
                        .font(NotchStyle.detail).foregroundStyle(NotchStyle.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Equalizer(playing: bridge.isPlaying)
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                NotchGelButton(action: { bridge.send("previous track") }) {
                    Image(systemName: "backward.fill").font(.system(size: 9))
                }
                .accessibilityLabel("Previous track")
                NotchGelButton(on: true, size: CGSize(width: 32, height: 32), action: { bridge.send("playpause") }) {
                    Image(systemName: bridge.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 12))
                }
                .accessibilityLabel(bridge.isPlaying ? "Pause" : "Play")
                NotchGelButton(action: { bridge.send("next track") }) {
                    Image(systemName: "forward.fill").font(.system(size: 9))
                }
                .accessibilityLabel("Next track")
                Spacer(minLength: 0)
            }
            if let error = bridge.error {
                Text(error).font(.system(size: 10)).foregroundStyle(NotchStyle.tertiary).lineLimit(2)
            }
        }
    }
}

/// Four little bars that bob while something plays (drawn only then; still when paused,
/// and with Reduce Motion).
private struct Equalizer: View {
    let playing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !playing || reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4, id: \.self) { index in
                    let wave = playing && !reduceMotion ? (sin(time * (5 + Double(index) * 1.7) + Double(index)) + 1) / 2 : 0.25
                    Capsule().fill(AquaDark.hex(0x9ACBFC)).frame(width: 3, height: 4 + 12 * wave)
                }
            }
            .frame(height: 16, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Clock and stats

/// CPU and memory, read on this Mac once a second while the panel is open, never otherwise.
@MainActor @Observable
final class SystemStats {
    private(set) var cpu: Double?
    private(set) var memoryUsedGB: Double?
    let memoryTotalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastTicks: CPUUsage.Ticks?

    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastTicks = nil
    }

    private func sample() {
        if let ticks = Self.ticks() {
            if let lastTicks { cpu = CPUUsage.busy(from: lastTicks, to: ticks) }
            lastTicks = ticks
        }
        memoryUsedGB = Self.memoryUsed().map { $0 / 1_073_741_824 }
    }

    private static func ticks() -> CPUUsage.Ticks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUUsage.Ticks(user: UInt64(info.cpu_ticks.0), system: UInt64(info.cpu_ticks.1),
                              idle: UInt64(info.cpu_ticks.2), nice: UInt64(info.cpu_ticks.3))
    }

    /// App, wired and compressed memory, as Activity Monitor's "Memory Used" counts it.
    private static func memoryUsed() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = Double(getpagesize())
        let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        return (app + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
    }
}

/// The time, beside the ClickBait triangle, left of the notch.
@MainActor
final class ClockWidget: NotchWidget {
    let id = "clock"
    let placement = NotchPlacement.headerLeading
    var isAvailable: Bool { true }

    var view: AnyView {
        AnyView(
            HStack(spacing: 7) {
                CompanionTriangle(tone: .idle, pulsing: false).scaleEffect(0.7).frame(width: 14, height: 14)
                TimelineView(.everyMinute) { context in
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(NotchStyle.title)
                }
            }
            .accessibilityElement(children: .combine)
        )
    }
}

/// CPU and memory as small Aqua gauges, right of the notch; read only while the panel is open.
@MainActor
final class StatsWidget: NotchWidget {
    let id = "stats"
    let placement = NotchPlacement.headerTrailing
    private let stats = SystemStats()

    var isAvailable: Bool { true }
    func expanded() { stats.start() }
    func collapsed() { stats.stop() }

    var view: AnyView {
        AnyView(StatsView(stats: stats))
    }
}

private struct StatsView: View {
    let stats: SystemStats

    var body: some View {
        HStack(spacing: 8) {
            gauge("CPU", stats.cpu ?? 0)
            gauge("MEM", (stats.memoryUsedGB ?? 0) / max(stats.memoryTotalGB, 1))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    /// A recessed capsule with a blue gel fill.
    private func gauge(_ name: String, _ fraction: Double) -> some View {
        HStack(spacing: 4) {
            Text(name).font(NotchStyle.label).foregroundStyle(NotchStyle.tertiary).fixedSize()
            ZStack(alignment: .leading) {
                AquaWell(shape: Capsule(), darkness: 0.5, bordered: true)
                AquaGel(palette: .lightBlue, shape: Capsule())
                    .frame(width: max(6, 28 * min(max(fraction, 0), 1)))
            }
            .frame(width: 28, height: 7)
        }
    }

    private var label: String {
        let cpu = stats.cpu.map { "CPU \(Int(($0 * 100).rounded())) percent" } ?? "CPU reading"
        let memory = stats.memoryUsedGB.map { String(format: "memory %.1f of %.0f gigabytes", $0, stats.memoryTotalGB) } ?? ""
        return [cpu, memory].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

// MARK: - Quick note

/// A scratch note that stays on this Mac (`AppSettings.notchNote`).
@MainActor
final class NoteWidget: NotchWidget {
    let id = "note"
    let placement = NotchPlacement.shelf
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    var isAvailable: Bool { true }

    var view: AnyView {
        AnyView(NotchCard(title: "Note") { NoteWidgetView(settings: settings) })
    }
}

private struct NoteWidgetView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Jot something…", text: $settings.notchNote, axis: .vertical)
                .textFieldStyle(.plain)
                .font(NotchStyle.detail)
                .foregroundStyle(NotchStyle.title)
                .lineLimit(3...4)
                .accessibilityLabel("Quick note")
        }
    }
}

// MARK: - Battery

/// Charge and charging, from the power sources on this Mac; hidden on a Mac without a battery.
@MainActor
final class BatteryWidget: NotchWidget {
    let id = "battery"
    let placement = NotchPlacement.headerTrailing

    var isAvailable: Bool { Self.read() != nil }

    var view: AnyView {
        AnyView(TimelineView(.periodic(from: .now, by: 30)) { _ in
            if let battery = Self.read() { BatteryView(level: battery.level, charging: battery.charging) }
        })
    }

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

private struct BatteryView: View {
    let level: Double
    let charging: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text("\(Int((level * 100).rounded()))%").font(.system(size: 11, weight: .semibold)).foregroundStyle(NotchStyle.secondary)
                .fixedSize()
            ZStack(alignment: .leading) {
                AquaWell(shape: RoundedRectangle(cornerRadius: 3), darkness: 0.5, bordered: true)
                AquaGel(palette: level < 0.2 && !charging ? .red : .green, shape: RoundedRectangle(cornerRadius: 2))
                    .frame(width: max(3, 20 * level))
                    .padding(1.5)
                if charging {
                    Image(systemName: "bolt.fill").font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: 24, height: 11)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery \(Int((level * 100).rounded())) percent\(charging ? ", charging" : "")")
    }
}

// MARK: - Calendar

/// The next few events today and tomorrow, read on this Mac. Asks for access only when the
/// user presses Allow on the card.
@MainActor @Observable
final class CalendarSource {
    struct Event: Identifiable {
        let id: String
        let title: String
        let start: Date
        let color: Color
    }

    private(set) var events: [Event] = []
    private(set) var allowed = false
    @ObservationIgnored private let store = EKEventStore()

    func refresh() {
        allowed = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        guard allowed else { events = []; return }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(36 * 3600), calendars: nil)
        events = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
            .prefix(3)
            .map { Event(id: $0.eventIdentifier ?? UUID().uuidString, title: $0.title ?? "Event", start: $0.startDate,
                         color: Color(nsColor: $0.calendar.color ?? .systemBlue)) }
    }

    func requestAccess() {
        Task {
            _ = try? await store.requestFullAccessToEvents()
            refresh()
        }
    }
}

@MainActor
final class CalendarWidget: NotchWidget {
    let id = "calendar"
    let placement = NotchPlacement.card
    private let source = CalendarSource()

    var isAvailable: Bool { true }
    func expanded() { source.refresh() }

    var view: AnyView {
        AnyView(NotchCard(title: "Up next") { CalendarView(source: source) })
    }
}

private struct CalendarView: View {
    let source: CalendarSource

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !source.allowed {
                Text("See your next events here.").font(NotchStyle.detail).foregroundStyle(NotchStyle.secondary)
                NotchGelButton(on: true, size: CGSize(width: 56, height: 18), action: source.requestAccess) {
                    Text("Allow").font(.system(size: 10, weight: .semibold))
                }
                .accessibilityLabel("Allow calendar access")
            } else if source.events.isEmpty {
                Text("Nothing coming up").font(NotchStyle.detail).foregroundStyle(NotchStyle.secondary)
            }
            ForEach(source.events) { event in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    RoundedRectangle(cornerRadius: 1).fill(event.color).frame(width: 3, height: 11)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(event.title).font(NotchStyle.body).foregroundStyle(NotchStyle.title).lineLimit(1)
                        Text(event.start, format: .dateTime.weekday(.abbreviated).hour().minute())
                            .font(NotchStyle.detail).foregroundStyle(NotchStyle.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: - File shelf

/// A place to park files for a moment: drop them on the shelf, drag them out to anywhere,
/// click one to show it in Finder. Only references, for this session; nothing is copied,
/// moved or deleted.
@MainActor @Observable
final class ShelfStore {
    private(set) var files: [URL] = []

    func add(_ urls: [URL]) {
        for url in urls where !files.contains(url) { files.append(url) }
        if files.count > 12 { files.removeFirst(files.count - 12) }
    }

    func remove(_ url: URL) { files.removeAll { $0 == url } }
}

@MainActor
final class ShelfWidget: NotchWidget {
    let id = "shelf"
    let placement = NotchPlacement.shelf
    private let store = ShelfStore()

    var isAvailable: Bool { true }

    var view: AnyView {
        AnyView(NotchCard(title: "Shelf") { ShelfView(store: store) })
    }
}

private struct ShelfView: View {
    let store: ShelfStore
    @State private var targeted = false

    var body: some View {
        ZStack {
            if store.files.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 18)).foregroundStyle(NotchStyle.tertiary)
                    Text("Drop files here").font(NotchStyle.detail).foregroundStyle(NotchStyle.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(store.files, id: \.self) { url in file(url) }
                    }
                }
            }
        }
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 8).strokeBorder(AquaDark.link, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            store.add(files)
            return !files.isEmpty
        } isTargeted: { targeted = $0 }
        .accessibilityLabel(store.files.isEmpty ? "File shelf, empty. Drop files here." : "File shelf, \(store.files.count) files")
    }

    private func file(_ url: URL) -> some View {
        VStack(spacing: 3) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 34, height: 34)
            Text(url.lastPathComponent).font(.system(size: 10)).foregroundStyle(NotchStyle.secondary)
                .lineLimit(1).frame(width: 60)
        }
        .overlay(alignment: .topTrailing) {
            Button { store.remove(url) } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(NotchStyle.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(url.lastPathComponent) from the shelf")
        }
        .onTapGesture { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        .draggable(url)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(url.lastPathComponent)
        .accessibilityHint("Drag out to use it, or click to show it in Finder")
    }
}

// MARK: - Mirror

/// A quick look at yourself before a call: the camera, mirrored, only while the Mirror tab
/// shows in the open panel (stopped the moment it closes or another tab shows). Asks for the
/// camera only when the user presses Allow. Nothing is recorded or kept.
@MainActor @Observable
final class MirrorCamera {
    private(set) var allowed = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    private(set) var unavailable = false
    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private var configured = false

    func start() {
        allowed = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        guard allowed else { return }
        if !configured {
            guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { unavailable = true; return }
            session.sessionPreset = .medium
            session.addInput(input)
            configured = true
        }
        // Apple's own advice: start and stop on a background queue (they block a while); the
        // session is safe to drive from one serial queue.
        nonisolated(unsafe) let session = session
        Self.queue.async { if !session.isRunning { session.startRunning() } }
    }

    func stop() {
        nonisolated(unsafe) let session = session
        Self.queue.async { if session.isRunning { session.stopRunning() } }
    }

    private static let queue = DispatchQueue(label: "ClickBait.notch.mirror")

    func requestAccess() {
        Task {
            allowed = await AVCaptureDevice.requestAccess(for: .video)
            if allowed { start() }
        }
    }
}

@MainActor
final class MirrorWidget: NotchWidget {
    let id = "mirror"
    let placement = NotchPlacement.mirror
    private let camera = MirrorCamera()

    var isAvailable: Bool { true }
    func collapsed() { camera.stop() }

    var view: AnyView {
        AnyView(NotchCard(title: "Mirror") { MirrorView(camera: camera) })
    }
}

private struct MirrorView: View {
    let camera: MirrorCamera

    var body: some View {
        Group {
            if camera.unavailable {
                Text("No camera found.").font(NotchStyle.detail).foregroundStyle(NotchStyle.secondary)
            } else if camera.allowed {
                CameraPreview(session: camera.session)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityLabel("Camera mirror")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Check yourself before a call. Only while this tab is open; nothing is recorded.")
                        .font(NotchStyle.detail).foregroundStyle(NotchStyle.secondary).fixedSize(horizontal: false, vertical: true)
                    NotchGelButton(on: true, size: CGSize(width: 56, height: 18), action: camera.requestAccess) {
                        Text("Allow").font(.system(size: 10, weight: .semibold))
                    }
                    .accessibilityLabel("Allow camera access")
                }
            }
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }
}

/// The camera's live picture, mirrored like a mirror.
private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        if let connection = layer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
