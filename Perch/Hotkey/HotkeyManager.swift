import Carbon.HIToolbox

/// Global open/close shortcut via Carbon `RegisterEventHotKey` (no Accessibility permission needed).
final class HotkeyManager {
    static let shared = HotkeyManager()

    var onPress: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var current: Shortcut?

    private init() {}

    /// Registers `shortcut` and drops the previous one. Returns false (keeping the previous) when another app owns it.
    @discardableResult
    func register(_ shortcut: Shortcut) -> Bool {
        if shortcut == current, hotKeyRef != nil { return true }
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let context = Unmanaged.passUnretained(self).toOpaque()
            guard InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, context, &handlerRef) == noErr else {
                return false
            }
        }
        var newRef: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x5052_4348), id: 1) // 'PRCH'
        guard RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &newRef) == noErr,
              let newRef else { return false }
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = newRef
        current = shortcut
        return true
    }

    /// Releases the OS-level hotkey so a recorder can see the keystroke. Remembers the shortcut for `resume()`.
    func suspend() {
        guard let hotKeyRef else { return }
        UnregisterEventHotKey(hotKeyRef)
        self.hotKeyRef = nil
    }

    func resume() {
        guard hotKeyRef == nil, let current else { return }
        register(current)
    }

    fileprivate func fire() { onPress?() }
}

/// Carbon delivers application-target events on the main thread.
nonisolated private func hotKeyHandler(_: EventHandlerCallRef?, _: EventRef?, _ context: UnsafeMutableRawPointer?) -> OSStatus {
    guard let context else { return OSStatus(eventNotHandledErr) }
    let address = UInt(bitPattern: context)
    MainActor.assumeIsolated {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
        Unmanaged<HotkeyManager>.fromOpaque(pointer).takeUnretainedValue().fire()
    }
    return noErr
}
