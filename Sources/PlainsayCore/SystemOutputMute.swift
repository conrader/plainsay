import CoreAudio
import Foundation

/// Silences the Mac's speakers while a dictation is being recorded.
///
/// Injectable so tests never touch the output of the machine running them.
@MainActor
public protocol SystemOutputMuting: AnyObject {
    func mute()
    /// Undoes `mute()`. Safe to call when nothing was muted.
    func restore()
}

/// Mutes the default output device through CoreAudio, not by pausing players:
/// a play/pause key toggles, so it would *start* music for anyone who had
/// none playing, and it does nothing for a browser tab or a call.
@MainActor
public final class SystemOutputMute: SystemOutputMuting {
    /// The device we muted, so the same one is unmuted even if the default
    /// output changes mid-dictation (headphones plugged in, AirPods connect).
    private var mutedDevice: AudioDeviceID?

    public init() {}

    public func mute() {
        guard mutedDevice == nil, let device = Self.defaultOutputDevice() else { return }
        // Already muted by the user: leave it, and leave it muted afterwards.
        guard Self.isMuted(device) == false else { return }
        guard Self.setMuted(true, device) else {
            // shortcut: devices without a settable mute (some HDMI/USB outputs) are left playing, add a volume fallback if anyone asks.
            Log.audio.info("default output has no settable mute; leaving it playing")
            return
        }
        mutedDevice = device
    }

    public func restore() {
        guard let device = mutedDevice else { return }
        mutedDevice = nil
        if !Self.setMuted(false, device) {
            Log.audio.error("could not unmute the output muted for dictation")
        }
    }

    private static var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func isMuted(_ device: AudioDeviceID) -> Bool? {
        guard AudioObjectHasProperty(device, &muteAddress) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private static func setMuted(_ muted: Bool, _ device: AudioDeviceID) -> Bool {
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &muteAddress),
              AudioObjectIsPropertySettable(device, &muteAddress, &settable) == noErr,
              settable.boolValue
        else { return false }
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(
            device, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value
        ) == noErr
    }
}
