import AppKit
import ApplicationServices

/// Reads and drives Zoom through its Accessibility menu bar. Needs the Accessibility permission.
///
/// State: the "Meeting" menu's item titles (see `CallLogic.zoomState`). Actions press those menu items,
/// which works while Zoom is in the background; if a menu item is missing the documented shortcut
/// (⌘⇧A audio, ⌘⇧V video) is posted to the Zoom process instead. Leave sends ⌘W, which makes Zoom
/// ask for confirmation, then presses the "Leave meeting" button of that dialog.
@MainActor
final class ZoomController {
    static let bundleID = "us.zoom.xos"

    private enum Key {
        static let a: CGKeyCode = 0
        static let v: CGKeyCode = 9
        static let w: CGKeyCode = 13
    }

    var app: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first
    }

    /// nil when Zoom is not running, Perch is not trusted, or no meeting is open.
    func state() -> CallState? {
        guard AXIsProcessTrusted(), let app else { return nil }
        return meetingItems(of: axApp(app)).state
    }

    func perform(_ actionID: String) {
        guard let app else { return }
        switch actionID {
        case CallActionID.mute:
            toggle(app, titlePrefixes: ["mute", "unmute"], needle: "audio", key: Key.a)
        case CallActionID.camera:
            toggle(app, titlePrefixes: ["start", "stop"], needle: "video", key: Key.v)
        case CallActionID.leave:
            leave(app)
        default:
            break
        }
    }

    // MARK: Actions

    private func toggle(_ app: NSRunningApplication, titlePrefixes: [String], needle: String, key: CGKeyCode) {
        if let item = meetingItems(of: axApp(app)).items.first(where: { element in
               guard let title = string(element, kAXTitleAttribute)?.lowercased() else { return false }
               return title.contains(needle) && titlePrefixes.contains { title.hasPrefix($0) }
           }),
           AXUIElementPerformAction(item, kAXPressAction as CFString) == .success {
            return
        }
        post(key: key, flags: [.maskCommand, .maskShift], to: app.processIdentifier)
    }

    private func leave(_ app: NSRunningApplication) {
        post(key: Key.w, flags: .maskCommand, to: app.processIdentifier)
        // The confirmation appears a moment later; look a few times rather than guessing a delay.
        let pid = app.processIdentifier
        var done = false
        for attempt in 1...5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 * Double(attempt)) { [weak self] in
                MainActor.assumeIsolated {
                    guard !done, let self else { return }
                    done = self.pressLeaveConfirmation(pid: pid)
                }
            }
        }
    }

    private func pressLeaveConfirmation(pid: pid_t) -> Bool {
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.5)
        guard let button = findButton(in: root, depth: 0) else { return false }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    private func findButton(in element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 6 else { return nil }
        let roots = depth == 0
            ? (attribute(element, kAXWindowsAttribute) as? [AXUIElement] ?? [])
            : children(of: element)
        for child in roots {
            if string(child, kAXRoleAttribute) == kAXButtonRole,
               let title = string(child, kAXTitleAttribute) ?? string(child, kAXDescriptionAttribute),
               CallLogic.isLeaveButton(title) {
                return child
            }
            if let found = findButton(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    private func post(key: CGKeyCode, flags: CGEventFlags, to pid: pid_t) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { continue }
            event.flags = flags
            event.postToPid(pid)
        }
    }

    // MARK: AX helpers

    private func axApp(_ app: NSRunningApplication) -> AXUIElement {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        return element
    }

    /// The items of whichever menu bar menu carries the audio toggle ("Meeting" in English), so a
    /// localized menu name does not matter. Empty and nil while no meeting is open.
    private func meetingItems(of app: AXUIElement) -> (items: [AXUIElement], state: CallState?) {
        guard let bar = attribute(app, kAXMenuBarAttribute) else { return ([], nil) }
        // The attribute is an AXUIElement by contract.
        for barItem in children(of: bar as! AXUIElement) {
            guard let menu = children(of: barItem).first else { continue }
            let items = children(of: menu)
            if let state = CallLogic.zoomState(menuTitles: items.compactMap { string($0, kAXTitleAttribute) }) {
                return (items, state)
            }
        }
        return ([], nil)
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
