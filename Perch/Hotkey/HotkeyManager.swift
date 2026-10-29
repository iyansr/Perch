import Carbon.HIToolbox

/// Global open/close shortcut via Carbon `RegisterEventHotKey` (no Accessibility permission needed).
final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onPress: () -> Void

    init(onPress: @escaping () -> Void) {
        self.onPress = onPress
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Registers the shortcut, ⌥Space by default. Returns false when another app already owns it.
    @discardableResult
    func register(keyCode: Int = kVK_Space, modifiers: Int = optionKey) -> Bool {
        unregister()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, context, &handlerRef) == noErr else {
            return false
        }
        let id = EventHotKeyID(signature: OSType(0x5052_4348), id: 1) // 'PRCH'
        return RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }

    fileprivate func fire() { onPress() }
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
