import AppKit
import AudioToolbox
import CoreAudio

/// Reads volume, display brightness and keyboard backlight. Brightness and backlight have no
/// public API; both come from private frameworks loaded at runtime and return nil when missing.
enum SystemLevels {
    // MARK: Volume

    static func defaultOutputDevice() -> AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    static let volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    /// 0…1, or nil for devices without a main volume (HDMI, some interfaces).
    static func volume(of device: AudioObjectID) -> Double? {
        var address = volumeAddress
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr else { return nil }
        return Double(volume)
    }

    static func isMuted(_ device: AudioObjectID) -> Bool {
        var address = muteAddress
        guard AudioObjectHasProperty(device, &address) else { return false }
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr else { return false }
        return muted != 0
    }

    // MARK: Display brightness

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

    private static let getBrightness: GetBrightness? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let symbol = dlsym(handle, "DisplayServicesGetBrightness")
        else { return nil }
        return unsafeBitCast(symbol, to: GetBrightness.self)
    }()

    /// Brightness of the built-in display (or the main one), 0…1; nil when DisplayServices cannot
    /// read it, e.g. a closed lid with only external monitors.
    static func displayBrightness() -> Double? {
        guard let getBrightness else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count = UInt32(0)
        CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count)
        let online = ids.prefix(Int(count))
        let display = online.first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
        var brightness = Float(0)
        guard getBrightness(display, &brightness) == 0 else { return nil }
        return Double(min(max(brightness, 0), 1))
    }

    // MARK: Keyboard backlight

    private typealias BrightnessForKeyboard = @convention(c) (AnyObject, Selector, UInt64) -> Float

    private static let keyboardClient: (client: NSObject, ids: [UInt64], read: BrightnessForKeyboard)? = {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
              let type = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type,
              let method = class_getInstanceMethod(type, NSSelectorFromString("brightnessForKeyboard:"))
        else { return nil }
        let client = type.init()
        let ids = (client.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeRetainedValue() as? [NSNumber])?
            .map(\.uint64Value) ?? []
        guard !ids.isEmpty else { return nil }
        return (client, ids, unsafeBitCast(method_getImplementation(method), to: BrightnessForKeyboard.self))
    }()

    /// 0…1, or nil on Macs without a backlit keyboard.
    static func keyboardBacklight() -> Double? {
        guard let keyboard = keyboardClient, let id = keyboard.ids.first else { return nil }
        let level = keyboard.read(keyboard.client, NSSelectorFromString("brightnessForKeyboard:"), id)
        return Double(min(max(level, 0), 1))
    }
}
