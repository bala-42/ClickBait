import AppKit
import CoreAudio
import Foundation
import Observation
import OSLog

/// The Volume page's state (user's ask, 2026-11-02, after Vorssaint's mixer): the apps playing
/// sound, each one's volume (100% untouched: no tap), the main volume and the devices. An app is
/// tapped only while its volume is off 100%; one that stops playing or quits loses its tap.
@MainActor @Observable
final class AppVolumeMixer {
    static let shared = AppVolumeMixer()
    /// Up to 150%: a boost through the tap's soft limiter.
    static let maximum = 1.5

    private(set) var apps: [SystemAudio.PlayingApp] = []
    /// By app (bundle identifier): 1 is untouched.
    private(set) var volumes: [String: Double] = [:]
    private(set) var mainVolume: Double = SystemAudio.outputVolume() ?? 0.5
    private(set) var outputs: [SystemAudio.Device] = []
    private(set) var inputs: [SystemAudio.Device] = []
    private(set) var output: AudioObjectID?
    private(set) var systemOutput: AudioObjectID?
    private(set) var input: AudioObjectID?
    private(set) var inputVolume: Double?
    /// Why the last volume change didn't take, if it didn't ("allow ClickBait to record…").
    private(set) var problem: String?

    @ObservationIgnored private var taps: [String: AppVolumeTap] = [:]
    @ObservationIgnored private var tappedOutput: AudioObjectID?

    private init() {}

    func volume(of app: SystemAudio.PlayingApp) -> Double { volumes[app.bundleID] ?? 1 }

    /// Read again (once a second while the page shows).
    func refresh() {
        outputs = SystemAudio.outputs()
        inputs = SystemAudio.inputs()
        output = SystemAudio.defaultOutput
        systemOutput = SystemAudio.defaultSystemOutput
        input = SystemAudio.defaultInput
        inputVolume = SystemAudio.inputVolume()
        if let level = SystemAudio.outputVolume() { mainVolume = level }
        // Tapped apps stay listed while tapped (a tapped app no longer counts as playing).
        let playing = SystemAudio.playingApps()
        let kept = apps.filter { taps[$0.bundleID] != nil && !playing.contains($0) }
        apps = (playing + kept).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        // The output changed: taps play to the old one, so they're made again.
        if let output, output != tappedOutput, !taps.isEmpty {
            let wanted = taps.keys.compactMap { key in apps.first { $0.bundleID == key }.map { ($0, volumes[key] ?? 1) } }
            stopAll()
            for (app, level) in wanted { setVolume(level, for: app) }
        }
        // An app gone from the Mac: its tap goes.
        let running = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        for app in apps where taps[app.bundleID] != nil && !running.contains(app.pid) {
            taps.removeValue(forKey: app.bundleID)?.stop()
        }
    }

    func setMainVolume(_ level: Double) {
        mainVolume = level
        SystemAudio.setOutputVolume(level)
    }

    func setInputVolume(_ level: Double) {
        inputVolume = level
        SystemAudio.setInputVolume(level)
    }

    func setVolume(_ level: Double, for app: SystemAudio.PlayingApp) {
        let level = min(Self.maximum, max(0, level))
        volumes[app.bundleID] = level
        problem = nil
        // Back at 100%: the app plays as it always does, untapped.
        if abs(level - 1) < 0.01 {
            volumes[app.bundleID] = nil
            taps.removeValue(forKey: app.bundleID)?.stop()
            return
        }
        if let tap = taps[app.bundleID] { tap.setGain(Float(level)); return }
        guard let output, let uid = outputs.first(where: { $0.id == output })?.uid,
              let tap = AppVolumeTap(process: app.id, outputUID: uid, gain: Float(level)) else {
            volumes[app.bundleID] = nil
            problem = "couldn't change \(app.name)'s volume — allow ClickBait in System Settings → Privacy & Security → Screen & System Audio Recording"
            return
        }
        taps[app.bundleID] = tap
        tappedOutput = output
        Log.app.notice("Volume: \(app.name, privacy: .public) at \(Int(level * 100), privacy: .public)%")
    }

    func reset(_ app: SystemAudio.PlayingApp) { setVolume(1, for: app) }

    func choose(output device: AudioObjectID) { SystemAudio.setDefaultOutput(device); refresh() }
    func choose(systemOutput device: AudioObjectID) { SystemAudio.setDefaultSystemOutput(device); refresh() }
    func choose(input device: AudioObjectID) { SystemAudio.setDefaultInput(device); refresh() }

    /// Every app back to normal (ClickBait quitting, the output changing).
    func stopAll() {
        for tap in taps.values { tap.stop() }
        taps = [:]
    }
}
