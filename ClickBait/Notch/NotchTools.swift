import AppKit
import ClickBaitCore
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// Tools (user's ask, 2026-11-02, after Vorssaint's; it took Watch's tile): Cleaning mode,
/// Uninstaller, Brightness (screen and keyboard), Mute mic.
struct ToolsPage: View {
    @State private var showsBrightness = false
    @State private var micMuted = SystemAudio.inputMuted
    @State private var screen = SystemBrightness.read()
    @State private var keyboard = KeyboardBrightness.read()

    var cleaning = CleaningMode.shared

    var body: some View {
        if cleaning.on { CleaningCard(cleaning: cleaning) } else if showsBrightness { brightness } else { tiles }
    }

    private var tiles: some View {
        HStack(spacing: 8) {
            tile("Cleaning mode", "sparkles", "lock the keyboard to wipe it") { GalleryHooks.tool(.cleaning) }
            tile("Uninstaller", "trash", "an app and its leftovers") { GalleryHooks.tool(.uninstall) }
            tile("Brightness", "sun.max", "screen and keyboard") {
                (screen, keyboard) = (SystemBrightness.read(), KeyboardBrightness.read())
                showsBrightness = true
            }
            tile(micMuted ? "Mic muted" : "Mute mic", micMuted ? "mic.slash.fill" : "mic", micMuted ? "tap to unmute" : "the microphone off",
                 lit: micMuted) {
                SystemAudio.setInputMuted(!micMuted)
                micMuted = SystemAudio.inputMuted
                GalleryHooks.say(micMuted ? "microphone muted" : "microphone on")
            }
        }
        .foregroundStyle(NotchPalette.text)
    }

    private var brightness: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { showsBrightness = false } label: { Label("Tools", systemImage: "chevron.left").font(.system(size: 11)) }
                .buttonStyle(.plain).foregroundStyle(NotchPalette.secondary)
            slider("Screen", "sun.max", value: screen) { level in
                if SystemBrightness.write(level) { screen = level }
            }
            slider("Keyboard", "light.max", value: keyboard) { level in
                if KeyboardBrightness.write(level) { keyboard = level }
            }
        }
        .foregroundStyle(NotchPalette.text)
    }

    private func slider(_ title: String, _ symbol: String, value: Double?, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 12) {
            Label(title, systemImage: symbol).font(.system(size: 12)).frame(width: 96, alignment: .leading)
            if let value {
                Slider(value: Binding(get: { value }, set: set), in: 0...1).controlSize(.small).tint(NotchPalette.text)
                Text("\(Int((value * 100).rounded()))%").font(.system(size: 11).monospacedDigit()).foregroundStyle(NotchPalette.secondary)
                    .frame(width: 36, alignment: .trailing)
            } else {
                Text("not on this Mac").font(.system(size: 11)).foregroundStyle(NotchPalette.tertiary)
            }
        }
    }

    private func tile(_ title: String, _ symbol: String, _ note: String, lit: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 20)).frame(height: 24).foregroundStyle(lit ? CompanionTone.problem : NotchPalette.text)
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(note).font(.system(size: 10)).foregroundStyle(NotchPalette.tertiary).multilineTextAlignment(.center).lineLimit(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 104)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(lit ? 0.12 : 0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PlayerPressStyle())
    }
}

enum ToolAction { case cleaning, uninstall }

/// Cleaning mode (Tools), in the notch (user's choice, 2026-11-03: not the whole screen): the
/// keyboard locked, and clicks and scrolling anywhere but the notch (`InputInterceptor.lockKeys`),
/// the screen left as it is; the notch stays open on a card with a clock and Done. It ends itself
/// after five minutes, in case.
@MainActor @Observable
final class CleaningMode {
    static let shared = CleaningMode()
    @ObservationIgnored var lock: (Bool) -> Void = { _ in }
    private(set) var startedAt: Date?
    var on: Bool { startedAt != nil }
    @ObservationIgnored private var timeout: Task<Void, Never>?

    func start() {
        guard !on else { return }
        startedAt = Date()
        lock(true)
        Log.app.notice("Cleaning mode on")
        timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        guard on else { return }
        timeout?.cancel()
        lock(false)
        startedAt = nil
        Log.app.notice("Cleaning mode off")
    }
}

/// The notch's card while cleaning: what's locked, how long, and Done.
struct CleaningCard: View {
    let cleaning: CleaningMode

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "sparkles").font(.system(size: 24)).foregroundStyle(MoodyLook.cream)
            VStack(alignment: .leading, spacing: 4) {
                Text("Cleaning mode").font(.system(size: 13, weight: .semibold))
                Text("Keyboard and clicks locked — wipe away.").font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
            }
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(AgentLive.clock(context.date.timeIntervalSince(cleaning.startedAt ?? context.date)))
                    .font(.system(size: 13, weight: .medium).monospacedDigit()).foregroundStyle(NotchPalette.secondary)
            }
            Button { cleaning.stop() } label: {
                Text("Done").font(.system(size: 13, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 20).frame(height: 30).background(Capsule().fill(NotchPalette.text))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 104)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06)))
        .foregroundStyle(NotchPalette.text)
    }
}

/// Uninstaller (Tools): an app chosen in a panel, its leftovers found (`AppLeftovers`), and
/// after a card's yes, the app (quit first) and all of them moved to the Trash — not deleted.
@MainActor
enum AppRemover {
    struct Plan {
        let app: URL
        let name: String
        let bundleID: String
        let leftovers: [URL]
        let bytes: Int64
    }

    /// The app chosen, or nil (cancelled).
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Choose"
        panel.message = "Choose an app to remove, with what it left behind"
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url : nil
    }

    enum Outcome { case ready(Plan), refused(String) }

    static func plan(for app: URL) -> Outcome {
        let bundle = Bundle(url: app)
        let name = app.deletingPathExtension().lastPathComponent
        guard let bundleID = bundle?.bundleIdentifier, AppLeftovers.removable(bundleID: bundleID, path: app.path) else {
            return .refused("\(name) is part of macOS (or ClickBait), so it stays")
        }
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        var found = AppLeftovers.places(bundleID: bundleID, name: name).map { library.appending(path: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        for folder in AppLeftovers.scanned {
            let url = library.appending(path: folder)
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [] where AppLeftovers.belongs(entry, bundleID: bundleID) {
                found.append(url.appending(path: entry))
            }
        }
        let bytes = ([app] + found).reduce(Int64(0)) { $0 + size($1) }
        return .ready(Plan(app: app, name: name, bundleID: bundleID, leftovers: found, bytes: bytes))
    }

    /// Quits the app if it runs, then moves it and its leftovers to the Trash.
    static func remove(_ plan: Plan) async -> String {
        for running in NSRunningApplication.runningApplications(withBundleIdentifier: plan.bundleID) {
            running.terminate()
            for _ in 0..<20 where !running.isTerminated { try? await Task.sleep(for: .milliseconds(250)) }
            if !running.isTerminated { return "\(plan.name) is still open — quit it, then try again" }
        }
        do {
            _ = try await NSWorkspace.shared.recycle([plan.app] + plan.leftovers)
            Log.app.notice("Uninstalled an app with \(plan.leftovers.count, privacy: .public) leftovers")
            return "moved \(plan.name) and \(plan.leftovers.count) leftover\(plan.leftovers.count == 1 ? "" : "s") to the Trash ✓"
        } catch {
            return "couldn't move \(plan.name) to the Trash: \(error.localizedDescription)"
        }
    }

    private static func size(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else {
            return Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        var total: Int64 = Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        for case let file as URL in enumerator { total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0) }
        return total
    }
}
