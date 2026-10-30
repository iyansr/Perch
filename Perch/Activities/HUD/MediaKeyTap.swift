import AppKit

/// Watches (never consumes) the brightness, keyboard-backlight and Caps Lock keys.
/// Brightness/backlight arrive as `.systemDefined` aux-control events; on Apple silicon keyboards
/// brightness also comes as a plain key-down with key codes 144/145. Caps Lock is a flags change
/// with key code 57.
///
/// Uses NSEvent monitors, which macOS gates on Accessibility. A listen-only CGEvent tap was used before:
/// macOS created it even without permission and then delivered nothing, so the retry never ran.
/// The global monitor sees keys sent to other apps; the local one covers Perch's own panel.
final class MediaKeyTap {
    enum Key: Equatable {
        case brightness, keyboardBacklight
        case capsLock(on: Bool)
    }

    /// NX_KEYTYPE_* codes inside an aux-control event's `data1`.
    private static let auxKeys: [Int: Key] = [2: .brightness, 3: .brightness, 21: .keyboardBacklight, 22: .keyboardBacklight, 23: .keyboardBacklight]
    private static let brightnessKeyCodes: Set<UInt16> = [144, 145]
    private static let capsLockKeyCode: UInt16 = 57
    private static let mask: NSEvent.EventTypeMask = [.systemDefined, .keyDown, .flagsChanged]

    private var monitors: [Any] = []
    private let onKey: (Key) -> Void

    init(onKey: @escaping (Key) -> Void) {
        self.onKey = onKey
    }

    var isRunning: Bool { !monitors.isEmpty }

    /// Returns false while Accessibility is not granted: a global monitor installed then never receives keys.
    @discardableResult
    func start() -> Bool {
        guard monitors.isEmpty else { return true }
        guard AccessibilityPermission.isTrusted else { return false }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: Self.mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: Self.mask, handler: { [weak self] event in
            self?.handle(event)
            return event
        }) {
            monitors.append(local)
        }
        return !monitors.isEmpty
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            if Self.brightnessKeyCodes.contains(event.keyCode) { onKey(.brightness) }
        case .flagsChanged:
            guard event.keyCode == Self.capsLockKeyCode else { return }
            onKey(.capsLock(on: event.modifierFlags.contains(.capsLock)))
        case .systemDefined:
            guard event.subtype.rawValue == 8 else { return }
            let code = (event.data1 & 0xFFFF_0000) >> 16
            let isDown = (event.data1 & 0xFF00) >> 8 == 0xA
            if isDown, let key = Self.auxKeys[code] { onKey(key) }
        default:
            break
        }
    }
}
