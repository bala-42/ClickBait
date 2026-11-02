import AppKit
import ClickBaitCore
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

    /// Apps kept first in the row (bundle identifiers), kept between launches.
    private(set) var pinned: [String] = UserDefaults.standard.stringArray(forKey: "mixerPinned") ?? []
    /// Headphones out, the speakers start quiet (`HeadphoneGuard`); on unless turned off.
    var lowerWhenHeadphonesOut = UserDefaults.standard.object(forKey: "mixerLowerOnHeadphonesOut") as? Bool ?? true {
        didSet { UserDefaults.standard.set(lowerWhenHeadphonesOut, forKey: "mixerLowerOnHeadphonesOut") }
    }

    @ObservationIgnored private var taps: [String: AppVolumeTap] = [:]
    @ObservationIgnored private var lastKind: HeadphoneGuard.Output?
    @ObservationIgnored private var watchedDevice = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private let changed: AudioObjectPropertyListenerBlock = { _, _ in
        Task { @MainActor in AppVolumeMixer.shared.outputChanged() }
    }
    @ObservationIgnored private var tappedOutput: AudioObjectID?

    private init() {}

    func volume(of app: SystemAudio.PlayingApp) -> Double { volumes[app.bundleID] ?? 1 }

    /// By app (bundle identifier): the output it plays to instead of the Mac's (Vorssaint's
    /// per-app output: music on the speakers while a call uses the headset).
    private(set) var appOutputs: [String: String] = [:]

    func output(of app: SystemAudio.PlayingApp) -> String? { appOutputs[app.bundleID] }

    /// Read again (once a second while the page shows).
    func refresh() {
        outputs = SystemAudio.outputs()
        inputs = SystemAudio.inputs()
        output = SystemAudio.defaultOutput
        systemOutput = SystemAudio.defaultSystemOutput
        input = SystemAudio.defaultInput
        inputVolume = SystemAudio.inputVolume()
        if let level = SystemAudio.outputVolume() { mainVolume = level }
        let pins = pinned
        apps = SystemAudio.playingApps().sorted { a, b in
            let ia = pins.firstIndex(of: a.bundleID) ?? .max, ib = pins.firstIndex(of: b.bundleID) ?? .max
            return ia != ib ? ia < ib : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        // The Mac's output changed: taps playing to it are made again for the new one.
        if let output, output != tappedOutput {
            tappedOutput = output
            for app in apps where taps[app.bundleID] != nil && appOutputs[app.bundleID] == nil { retap(app) }
        }
        // An app gone: its tap goes.
        let listed = Set(apps.map(\.bundleID))
        for key in taps.keys where !listed.contains(key) { taps.removeValue(forKey: key)?.stop() }
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
        volumes[app.bundleID] = abs(level - 1) < 0.01 ? nil : level
        if let tap = taps[app.bundleID], tap.processes == app.processes, volumes[app.bundleID] != nil {
            tap.setGain(Float(level))
            return
        }
        retap(app)
    }

    /// `uid`: nil plays to the Mac's output.
    func setOutput(_ uid: String?, for app: SystemAudio.PlayingApp) {
        appOutputs[app.bundleID] = uid
        retap(app)
    }

    /// The app's tap as its volume and output want it: none at 100% on the Mac's output (the app
    /// plays as it always does), else one to its output at its gain.
    private func retap(_ app: SystemAudio.PlayingApp) {
        problem = nil
        taps.removeValue(forKey: app.bundleID)?.stop()
        let level = volumes[app.bundleID] ?? 1
        let chosen = appOutputs[app.bundleID]
        guard abs(level - 1) >= 0.01 || chosen != nil else { return }
        guard let uid = chosen ?? output.flatMap({ id in outputs.first { $0.id == id }?.uid }),
              let tap = AppVolumeTap(processes: app.processes, outputUID: uid, gain: Float(level)) else {
            volumes[app.bundleID] = nil
            appOutputs[app.bundleID] = nil
            problem = "couldn't change \(app.name)'s sound — allow ClickBait in System Settings → Privacy & Security → Screen & System Audio Recording"
            return
        }
        taps[app.bundleID] = tap
        tappedOutput = output
        Log.app.notice("Volume: \(app.name, privacy: .public) at \(Int(level * 100), privacy: .public)%\(chosen == nil ? "" : " on its own output", privacy: .public)")
    }

    func reset(_ app: SystemAudio.PlayingApp) { setVolume(1, for: app) }

    func togglePin(_ app: SystemAudio.PlayingApp) {
        if let index = pinned.firstIndex(of: app.bundleID) { pinned.remove(at: index) } else { pinned.append(app.bundleID) }
        UserDefaults.standard.set(pinned, forKey: "mixerPinned")
        refresh()
    }

    // MARK: Headphones out

    /// Listens for the Mac's output changing (another device, or the jack's plug pulled), from
    /// launch, the page open or not.
    func startHeadphoneGuard() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, changed)
        outputChanged()
    }

    private func outputChanged() {
        guard let device = SystemAudio.defaultOutput else { return }
        if device != watchedDevice {
            // The built-in output's plug: its data source changes, not the device.
            var source = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource,
                                                    mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            if watchedDevice != kAudioObjectUnknown { AudioObjectRemovePropertyListenerBlock(watchedDevice, &source, .main, changed) }
            AudioObjectAddPropertyListenerBlock(device, &source, .main, changed)
            watchedDevice = device
        }
        let kind = SystemAudio.outputKind(device)
        defer { lastKind = kind }
        guard lowerWhenHeadphonesOut, let old = lastKind, let current = SystemAudio.outputVolume(),
              let quiet = HeadphoneGuard.volume(after: current, from: old, to: kind) else { return }
        setMainVolume(quiet)
        Log.app.notice("Volume: headphones out, speakers at \(Int(quiet * 100), privacy: .public)%")
    }

    func choose(output device: AudioObjectID) { SystemAudio.setDefaultOutput(device); refresh() }
    func choose(systemOutput device: AudioObjectID) { SystemAudio.setDefaultSystemOutput(device); refresh() }
    func choose(input device: AudioObjectID) { SystemAudio.setDefaultInput(device); refresh() }

    /// Every app back to normal (ClickBait quitting).
    func stopAll() {
        for tap in taps.values { tap.stop() }
        taps = [:]
    }
}
