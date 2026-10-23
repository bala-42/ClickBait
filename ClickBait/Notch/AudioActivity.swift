import CoreAudio
import Foundation

/// Which apps are sending sound out right now, from CoreAudio's process list (macOS 14.2+):
/// how the notch tells a browser's video is playing, since browsers don't say. Read only; a
/// browser's sound comes from its helper (com.google.Chrome.helper), so match by prefix.
@MainActor
final class AudioActivity {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    /// Bundle ids of the processes playing sound now.
    static func playingBundleIDs() -> Set<String> {
        guard #available(macOS 14.2, *) else { return [] }
        var playing: Set<String> = []
        for process in processes() {
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var address = Self.address(kAudioProcessPropertyIsRunningOutput)
            guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running) == noErr, running != 0 else { continue }
            var bundle: Unmanaged<CFString>?
            size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            address = Self.address(kAudioProcessPropertyBundleID)
            guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &bundle) == noErr,
                  let id = bundle?.takeRetainedValue() as String?, !id.isEmpty else { continue }
            playing.insert(id)
        }
        return playing
    }

    private static func processes() -> [AudioObjectID] {
        guard #available(macOS 14.2, *) else { return [] }
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    // MARK: Watching

    private let changed: @MainActor () -> Void
    private var watched: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var pending: Task<Void, Never>?

    /// Calls `changed` (settled for 0.4 s) when any app starts or stops sending sound.
    init(changed: @escaping @MainActor () -> Void) {
        self.changed = changed
        guard #available(macOS 14.2, *) else { return }
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(Self.system, &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.rewatch() }
        }
        rewatch()
    }

    /// Listens to every process's "sending sound" switch; the list changes as apps come and go.
    private func rewatch() {
        guard #available(macOS 14.2, *) else { return }
        let now = Set(Self.processes())
        for (process, block) in watched where !now.contains(process) {
            var address = Self.address(kAudioProcessPropertyIsRunningOutput)
            AudioObjectRemovePropertyListenerBlock(process, &address, .main, block)
            watched[process] = nil
        }
        for process in now where watched[process] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.settle() }
            }
            var address = Self.address(kAudioProcessPropertyIsRunningOutput)
            if AudioObjectAddPropertyListenerBlock(process, &address, .main, block) == noErr { watched[process] = block }
        }
        settle()
    }

    private func settle() {
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.changed()
        }
    }
}
