import Carbon.HIToolbox

/// What a global shortcut does: open Perch, toggle dictation, or open a launcher item.
enum HotkeySlot: Hashable {
    case open
    case dictation
    /// A launcher item, by `LauncherItem.key`.
    case launcher(String)
}

/// Global shortcuts via Carbon `RegisterEventHotKey` (no Accessibility permission needed), one per slot.
final class HotkeyManager {
    static let shared = HotkeyManager()

    /// Presses of `.launcher` slots, with the item key. Fixed slots use `setHandler(_:for:)`.
    var onLauncherPress: ((String) -> Void)?
    private var handlers: [HotkeySlot: () -> Void] = [:]
    private var handlerRef: EventHandlerRef?
    /// What should be registered.
    private var desired: [HotkeySlot: Shortcut] = [:]
    /// What is registered with Carbon.
    private var registered: [HotkeySlot: (shortcut: Shortcut, ref: EventHotKeyRef, number: UInt32)] = [:]
    /// Carbon hotkey number → slot, to route a press.
    private var slots: [UInt32: HotkeySlot] = [:]
    private var nextNumber: UInt32 = 1
    private var isSuspended = false

    private init() {}

    func setHandler(_ handler: (() -> Void)?, for slot: HotkeySlot) {
        handlers[slot] = handler
    }

    /// Registers `shortcut` for `slot`, replacing the slot's previous one. Returns false when another app owns it;
    /// the slot then has no shortcut until the next `register` or `resume()`. While suspended, it is remembered.
    @discardableResult
    func register(_ shortcut: Shortcut, slot: HotkeySlot) -> Bool {
        desired[slot] = shortcut
        return isSuspended || !apply().contains(slot)
    }

    func unregister(slot: HotkeySlot) {
        desired[slot] = nil
        if !isSuspended { _ = apply() }
    }

    /// Replaces every launcher shortcut with `shortcuts` (by item key). Returns the keys another app already owns.
    @discardableResult
    func setLauncherShortcuts(_ shortcuts: [String: Shortcut]) -> [String] {
        desired = desired.filter { if case .launcher = $0.key { false } else { true } }
        for (key, shortcut) in shortcuts { desired[.launcher(key)] = shortcut }
        guard !isSuspended else { return [] }
        return apply().compactMap { if case let .launcher(key) = $0 { key } else { nil } }
    }

    /// The slot whose shortcut is `shortcut`, if any.
    func owner(of shortcut: Shortcut) -> HotkeySlot? {
        desired.first { $0.value == shortcut }?.key
    }

    /// Whether `shortcut` is free system-wide. Perch's own shortcuts count as taken unless suspended.
    func isAvailable(_ shortcut: Shortcut) -> Bool {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 0)
        guard RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr,
              let ref else { return false }
        UnregisterEventHotKey(ref)
        return true
    }

    /// Releases every OS-level hotkey so a recorder can see the keystroke.
    func suspend() {
        isSuspended = true
        for entry in registered.values { UnregisterEventHotKey(entry.ref) }
        registered = [:]
        slots = [:]
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        for slot in apply() { NSLog("Perch: shortcut for \(slot) is already taken by another app.") }
    }

    private static let signature = OSType(0x5052_4348) // 'PRCH'

    /// Makes Carbon's registrations match `desired`. Returns the slots that could not be registered.
    private func apply() -> [HotkeySlot] {
        guard installHandler() else { return Array(desired.keys) }
        for (slot, entry) in registered where desired[slot] != entry.shortcut {
            UnregisterEventHotKey(entry.ref)
            registered[slot] = nil
            slots[entry.number] = nil
        }
        var failed: [HotkeySlot] = []
        for (slot, shortcut) in desired where registered[slot] == nil {
            let number = nextNumber
            nextNumber += 1
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: number)
            if RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr,
               let ref {
                registered[slot] = (shortcut, ref, number)
                slots[number] = slot
            } else {
                failed.append(slot)
            }
        }
        return failed
    }

    private func installHandler() -> Bool {
        guard handlerRef == nil else { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        return InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, context, &handlerRef) == noErr
    }

    fileprivate func fire(_ number: UInt32) {
        guard let slot = slots[number] else { return }
        if case let .launcher(key) = slot {
            onLauncherPress?(key)
        } else {
            handlers[slot]?()
        }
    }
}

/// Carbon delivers application-target events on the main thread.
nonisolated private func hotKeyHandler(_: EventHandlerCallRef?, _ event: EventRef?, _ context: UnsafeMutableRawPointer?) -> OSStatus {
    guard let context, let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return status }
    let address = UInt(bitPattern: context)
    let number = hotKeyID.id
    MainActor.assumeIsolated {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
        Unmanaged<HotkeyManager>.fromOpaque(pointer).takeUnretainedValue().fire(number)
    }
    return noErr
}
