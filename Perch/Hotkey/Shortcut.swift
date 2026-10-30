import AppKit
import Carbon.HIToolbox

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let `default` = Shortcut(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey))

    /// Builds a shortcut from a key event; nil when no ⌃⌥⇧⌘ modifier is held.
    init?(event: NSEvent) {
        let carbon = Shortcut.carbonModifiers(from: event.modifierFlags)
        guard carbon != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: carbon)
    }

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result = 0
        if flags.contains(.control) { result |= controlKey }
        if flags.contains(.option) { result |= optionKey }
        if flags.contains(.shift) { result |= shiftKey }
        if flags.contains(.command) { result |= cmdKey }
        return UInt32(result)
    }

    var displayString: String { keys.joined() }

    /// Modifier symbols in ⌃⌥⇧⌘ order, then the key name.
    var keys: [String] {
        var keys: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { keys.append("⌃") }
        if carbonModifiers & UInt32(optionKey) != 0 { keys.append("⌥") }
        if carbonModifiers & UInt32(shiftKey) != 0 { keys.append("⇧") }
        if carbonModifiers & UInt32(cmdKey) != 0 { keys.append("⌘") }
        return keys + [Shortcut.keyName(keyCode)]
    }

    private static func keyName(_ code: UInt32) -> String {
        let named: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_Escape: "⎋",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let name = named[Int(code)] { return name }
        if let name = layoutCharacter(code) { return name.uppercased() }
        return "Key \(code)"
    }

    private static func layoutCharacter(_ code: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &dead, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}
