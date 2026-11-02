import AppKit
import AudioToolbox
import CoreAudio
import Foundation

/// The Mac's audio devices and levels, straight from Core Audio, for the Volume page (user's ask,
/// 2026-11-02, after Vorssaint's mixer): output and system-sounds devices, the main volume, the
/// microphone and its level, and which apps are playing sound now.
extension SystemAudio {
    struct Device: Identifiable, Equatable {
        let id: AudioObjectID
        let uid: String
        let name: String
    }

    /// An app using sound, with all its Core Audio process objects (a browser's audio helper
    /// counts as the browser): what a tap is made from.
    struct PlayingApp: Identifiable, Equatable {
        var id: String { bundleID }
        let processes: [AudioObjectID]
        let pid: pid_t
        let bundleID: String
        let name: String
        let icon: NSImage?
        /// Sending sound out right now.
        let playing: Bool
        static func == (a: PlayingApp, b: PlayingApp) -> Bool { a.bundleID == b.bundleID && a.processes == b.processes && a.playing == b.playing }
    }

    // MARK: Devices

    static func outputs() -> [Device] { devices(scope: kAudioObjectPropertyScopeOutput) }
    static func inputs() -> [Device] { devices(scope: kAudioObjectPropertyScopeInput) }

    static var defaultOutput: AudioObjectID? { systemObject(kAudioHardwarePropertyDefaultOutputDevice) }
    static var defaultSystemOutput: AudioObjectID? { systemObject(kAudioHardwarePropertyDefaultSystemOutputDevice) }
    static var defaultInput: AudioObjectID? { systemObject(kAudioHardwarePropertyDefaultInputDevice) }

    static func setDefaultOutput(_ device: AudioObjectID) { setSystemObject(kAudioHardwarePropertyDefaultOutputDevice, device) }
    static func setDefaultSystemOutput(_ device: AudioObjectID) { setSystemObject(kAudioHardwarePropertyDefaultSystemOutputDevice, device) }
    static func setDefaultInput(_ device: AudioObjectID) { setSystemObject(kAudioHardwarePropertyDefaultInputDevice, device) }

    // MARK: Levels (0…1)

    /// The output's main volume (its virtual main control, as the volume keys use).
    static func outputVolume() -> Double? {
        guard let device = defaultOutput else { return nil }
        return scalar(device, mainVolume(kAudioObjectPropertyScopeOutput))
    }

    static func setOutputVolume(_ value: Double) {
        guard let device = defaultOutput else { return }
        setScalar(device, mainVolume(kAudioObjectPropertyScopeOutput), value)
    }

    static func inputVolume() -> Double? {
        guard let device = defaultInput else { return nil }
        return scalar(device, mainVolume(kAudioObjectPropertyScopeInput))
            ?? scalar(device, AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                         mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain))
    }

    static func setInputVolume(_ value: Double) {
        guard let device = defaultInput else { return }
        if scalar(device, mainVolume(kAudioObjectPropertyScopeInput)) != nil {
            setScalar(device, mainVolume(kAudioObjectPropertyScopeInput), value)
        } else {
            setScalar(device, AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                         mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain), value)
        }
    }

    // MARK: Apps using sound

    /// Apps with sound (Core Audio clients, as Vorssaint's mixer lists them), ClickBait aside,
    /// one row each: a helper process goes to the app it belongs to (by bundle identifier
    /// prefix: "com.google.Chrome.helper" → Chrome); background processes without an app are
    /// left out. By name.
    static func playingApps() -> [PlayingApp] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != me }
        var grouped: [String: (owner: NSRunningApplication, processes: [AudioObjectID], playing: Bool)] = [:]
        for object in objects {
            guard let pid = int32(object, kAudioProcessPropertyPID), pid != me else { continue }
            let running = NSRunningApplication(processIdentifier: pid)
            let bundleID = string(object, kAudioProcessPropertyBundleID) ?? running?.bundleIdentifier ?? ""
            let owner = apps.first { $0.processIdentifier == pid }
                ?? apps.filter { app in app.bundleIdentifier.map { !bundleID.isEmpty && bundleID.hasPrefix($0) } ?? false }
                    .max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
            guard let owner, let key = owner.bundleIdentifier else { continue }
            var entry = grouped[key] ?? (owner, [], false)
            entry.processes.append(object)
            entry.playing = entry.playing || uint32(object, kAudioProcessPropertyIsRunningOutput) == 1
            grouped[key] = entry
        }
        return grouped.map { key, entry in
            PlayingApp(processes: entry.processes, pid: entry.owner.processIdentifier, bundleID: key,
                       name: entry.owner.localizedName ?? key, icon: entry.owner.icon, playing: entry.playing)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Core Audio plumbing

    private static func mainVolume(_ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func devices(scope: AudioObjectPropertyScope) -> [Device] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName),
                  !uid.hasPrefix("ClickBait") else { return nil }  // never its own private devices
            return Device(id: id, uid: uid, name: name)
        }
    }

    private static func systemObject(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioObjectID(0), size = UInt32(MemoryLayout<AudioObjectID>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr && id != 0 ? id : nil
    }

    private static func setSystemObject(_ selector: AudioObjectPropertySelector, _ value: AudioObjectID) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = value
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &id)
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let text = value?.takeRetainedValue() else { return nil }
        return text as String
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func int32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> pid_t? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: pid_t = 0, size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func scalar(_ device: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Double? {
        var address = address
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0, size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? Double(value) : nil
    }

    private static func setScalar(_ device: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: Double) {
        var address = address
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &address), AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return }
        var level = Float32(min(1, max(0, value)))
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &level)
    }
}
