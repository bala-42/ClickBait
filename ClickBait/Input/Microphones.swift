@preconcurrency import AVFoundation
import CoreAudio
import Observation

/// The Mac's microphones (CoreAudio input devices) and the one ClickBait listens through
/// (`AppSettings.microphoneUID`; nil follows the system default).
enum Microphones {
    struct Device: Identifiable, Hashable {
        /// CoreAudio's UID: stays the same across launches and reconnects.
        let id: String
        let name: String
        let audioID: AudioDeviceID
    }

    static let defaultsKey = "settings.microphoneUID"
    static var chosenUID: String? { UserDefaults.standard.string(forKey: defaultsKey) }

    /// Every device with input channels, by name.
    static func all() -> [Device] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Device(id: uid, name: name, audioID: id)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Points the engine's input at the chosen microphone, before its format is read. A chosen
    /// one that's gone (unplugged) leaves the system default.
    static func apply(to engine: AVAudioEngine) {
        guard let uid = chosenUID, let device = all().first(where: { $0.id == uid }),
              let unit = engine.inputNode.audioUnit else { return }
        var id = device.audioID
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr { Log.input.error("Microphone: couldn't use the chosen one (\(status, privacy: .public))") }
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

/// Settings' "Test microphone": listens through the chosen microphone for a few seconds and
/// shows how loud it hears you. Nothing is kept.
@MainActor @Observable
final class MicrophoneTest {
    /// 0…1 while testing.
    private(set) var level: Float = 0
    private(set) var isRunning = false
    private(set) var failure: String?
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var stopTask: Task<Void, Never>?

    func start() {
        stop()
        failure = nil
        let engine = AVAudioEngine()
        Microphones.apply(to: engine)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { failure = "No microphone is available."; return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let samples = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<count { sum += samples[i] * samples[i] }
            let rms = count > 0 ? (sum / Float(count)).squareRoot() : 0
            let shown = min(1, rms * 12)  // speech sits around 0.02–0.08 RMS
            Task { @MainActor in self?.level = shown }
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            failure = "Couldn't open the microphone."
            return
        }
        self.engine = engine
        isRunning = true
        stopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        stopTask?.cancel()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRunning = false
        level = 0
    }
}
