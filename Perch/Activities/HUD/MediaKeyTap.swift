import AppKit
import CoreGraphics

/// Listens (never consumes) for the brightness and keyboard-backlight keys.
/// They arrive as `NX_SYSDEFINED` aux-control events; on Apple silicon keyboards brightness also
/// comes as a plain key-down with key codes 144/145. Needs Accessibility.
final class MediaKeyTap {
    enum Key {
        case brightness, keyboardBacklight
    }

    /// `NX_SYSDEFINED`; CGEventType has no case for it.
    private static let systemDefined = CGEventType(rawValue: 14)!
    /// NX_KEYTYPE_* codes inside an aux-control event's `data1`.
    private static let auxKeys: [Int: Key] = [2: .brightness, 3: .brightness, 21: .keyboardBacklight, 22: .keyboardBacklight, 23: .keyboardBacklight]
    private static let brightnessKeyCodes: Set<Int64> = [144, 145]

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let onKey: (Key) -> Void

    init(onKey: @escaping (Key) -> Void) {
        self.onKey = onKey
    }

    var isRunning: Bool { tap != nil }

    /// Returns false when the tap cannot be created, i.e. Accessibility is not granted yet.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (CGEventMask(1) << Self.systemDefined.rawValue) | (CGEventMask(1) << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                let tap = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
                MainActor.assumeIsolated { tap.handle(type, event) }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        runLoopSource = source
        return true
    }

    func stop() {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        runLoopSource = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            if Self.brightnessKeyCodes.contains(event.getIntegerValueField(.keyboardEventKeycode)) { onKey(.brightness) }
        case Self.systemDefined:
            guard let event = NSEvent(cgEvent: event), event.subtype.rawValue == 8 else { return }
            let code = (event.data1 & 0xFFFF_0000) >> 16
            let isDown = (event.data1 & 0xFF00) >> 8 == 0xA
            if isDown, let key = Self.auxKeys[code] { onKey(key) }
        default:
            break
        }
    }
}
