import CoreAudio
import Foundation

/// Mutes the Mac's default output device while a client is connected, then restores it.
/// ScreenCaptureKit taps app audio before the device, so the stream keeps its sound.
enum SpeakerMute {
    /// Persisted so a crash while muted gets undone on the next launch.
    private static let defaultsKey = "mutedOutputDevice"
    private static var mutedDevice: AudioDeviceID?

    static func mute() {
        guard mutedDevice == nil, let device = defaultOutputDevice(), isMuted(device) == false else { return }
        guard setMuted(device, true) else {
            hostLog("[audio] output device \(device) can't be muted")
            return
        }
        mutedDevice = device
        UserDefaults.standard.set(Int(device), forKey: defaultsKey)
        hostLog("[audio] muted Mac output while connected")
    }

    /// Unmutes only a device this app muted (now or before a crash).
    static func restore() {
        let saved = (UserDefaults.standard.object(forKey: defaultsKey) as? Int).map { AudioDeviceID($0) }
        guard let device = mutedDevice ?? saved else { return }
        _ = setMuted(device, false)
        mutedDevice = nil
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        hostLog("[audio] restored Mac output")
    }

    // MARK: CoreAudio

    private static var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    private static func isMuted(_ device: AudioDeviceID) -> Bool? {
        guard AudioObjectHasProperty(device, &muteAddress) else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private static func setMuted(_ device: AudioDeviceID, _ muted: Bool) -> Bool {
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &muteAddress),
              AudioObjectIsPropertySettable(device, &muteAddress, &settable) == noErr, settable.boolValue
        else { return false }
        var value = UInt32(muted ? 1 : 0)
        return AudioObjectSetPropertyData(device, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }
}
