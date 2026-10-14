import AudioToolbox
import CoreAudio

/// The default output device's volume and mute, through CoreAudio, for the notch's volume
/// HUD. Every call answers nil or false when the device can't do it (no volume control,
/// HDMI), and the HUD then leaves the key to macOS.
enum SystemVolume {
    private static func outputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    static func read() -> (volume: Double, muted: Bool)? {
        guard let device = outputDevice() else { return nil }
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var volumeAddress = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &volume) == noErr else { return nil }
        var mute = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        var muteAddress = address(kAudioDevicePropertyMute)
        let muted = AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &mute) == noErr && mute != 0
        return (Double(volume), muted)
    }

    /// False if the device refused (then nothing changed).
    static func write(volume: Double, muted: Bool) -> Bool {
        guard let device = outputDevice() else { return false }
        var value = Float32(min(max(volume, 0), 1))
        var volumeAddress = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &volumeAddress, &settable) == noErr, settable.boolValue,
              AudioObjectSetPropertyData(device, &volumeAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
        else { return false }
        var mute = UInt32(muted ? 1 : 0)
        var muteAddress = address(kAudioDevicePropertyMute)
        _ = AudioObjectSetPropertyData(device, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &mute)
        return true
    }
}
