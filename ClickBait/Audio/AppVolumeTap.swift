import AudioToolbox
import CoreAudio
import Foundation
import OSLog

/// One app's volume (user's ask, 2026-11-02, after Vorssaint's mixer, which needs no audio
/// driver): a Core Audio process tap takes the app's sound (its own output muted while tapped)
/// into a private aggregate device, and plays it out to the output at `gain` — boosted past 1
/// through a soft limiter. Made only while the app's slider is off 100%; anything unexpected
/// tears it down at once, so an app is never left silent.
final class AppVolumeTap {
    let process: AudioObjectID
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    /// Read on the audio thread; a Float store is atomic on Apple silicon.
    private let gain = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private let frames = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    /// Buffers played through so far (to check it's running).
    var framesProcessed: Int { frames.pointee }

    init?(process: AudioObjectID, outputUID: String, gain level: Float) {
        self.process = process
        gain.initialize(to: level)
        frames.initialize(to: 0)
        let description = CATapDescription(stereoMixdownOfProcesses: [process])
        description.uuid = UUID()
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        description.name = "ClickBait volume"
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr, tap != kAudioObjectUnknown else {
            Log.app.error("Volume: couldn't tap the app (permission, or macOS before 14.2)")
            return nil
        }
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ClickBait volume",
            kAudioAggregateDeviceUIDKey: "ClickBait-volume-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        guard AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregate) == noErr, aggregate != kAudioObjectUnknown,
              Self.isFloat32(aggregate, kAudioObjectPropertyScopeInput), Self.isFloat32(aggregate, kAudioObjectPropertyScopeOutput) else {
            Log.app.error("Volume: couldn't route the app's sound")
            teardown()
            return nil
        }
        let gain = self.gain, frames = self.frames
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil) { _, input, _, output, _ in
            let level = gain.pointee
            let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let outs = UnsafeMutableAudioBufferListPointer(output)
            for index in 0..<outs.count {
                guard let destination = outs[index].mData?.assumingMemoryBound(to: Float.self) else { continue }
                let count = Int(outs[index].mDataByteSize) / MemoryLayout<Float>.size
                var copied = 0
                if index < ins.count, let source = ins[index].mData?.assumingMemoryBound(to: Float.self) {
                    copied = min(count, Int(ins[index].mDataByteSize) / MemoryLayout<Float>.size)
                    for sample in 0..<copied {
                        let value = source[sample] * level
                        // Past full volume, a soft limiter keeps a boost from clipping harshly.
                        destination[sample] = level > 1 ? tanhf(value) : value
                    }
                }
                if copied < count { (destination + copied).update(repeating: 0, count: count - copied) }
            }
            frames.pointee += 1
        }
        guard status == noErr, let proc, AudioDeviceStart(aggregate, proc) == noErr else {
            Log.app.error("Volume: couldn't start playing the app's sound")
            teardown()
            return nil
        }
    }

    func setGain(_ level: Float) { gain.pointee = level }

    func stop() { teardown() }

    deinit {
        teardown()
        gain.deallocate()
        frames.deallocate()
    }

    private func teardown() {
        if let proc, aggregate != kAudioObjectUnknown {
            AudioDeviceStop(aggregate, proc)
            AudioDeviceDestroyIOProcID(aggregate, proc)
        }
        proc = nil
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
        aggregate = AudioObjectID(kAudioObjectUnknown)
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        tap = AudioObjectID(kAudioObjectUnknown)
    }

    /// The device's streams in that direction are 32-bit floats (what the copy above assumes).
    private static func isFloat32(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription(), size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &format) == noErr else { return true }  // not reported: the usual float
        return format.mFormatID == kAudioFormatLinearPCM && format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32
    }
}
