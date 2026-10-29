import AppKit
import SwiftUI

/// Borderless, non-activating panel pinned to the top edge of the screen.
/// It can become key (so the search field takes typing) without activating Perch,
/// which keeps the frontmost app's menu bar in place.
final class NotchPanel: NSPanel {
    init(frame: NSRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // Above the menu bar, below pop-up menus so the pill's context menu stays visible.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    private var allowsKey = true
    private lazy var keySink = KeySinkPanel()

    /// Drops key status without leaving the screen. Re-activating an app that is already
    /// frontmost does not take the key back from a non-activating panel, and ordering this
    /// panel out to force it would blink the visible pill.
    func releaseKey() {
        guard isKeyWindow else { return }
        allowsKey = false // AppKit must not hand the key straight back to this panel
        keySink.makeKeyAndOrderFront(nil)
        keySink.orderOut(nil)
        allowsKey = true
    }

    /// Borderless windows must be allowed to overlap the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Invisible, off-screen window that briefly takes the key so `NotchPanel` can drop it.
private final class KeySinkPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        alphaValue = 0
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click on the (never active) panel reach SwiftUI instead of only focusing the window.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    /// Receives file drags over the panel; setting it registers the view for `.fileURL`.
    weak var dropTarget: FileDropTarget? {
        didSet { registerForDraggedTypes(dropTarget == nil ? [] : [.fileURL]) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropTarget?.dragEntered(sender) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropTarget?.dragEntered(sender) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropTarget?.dragExited()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropTarget?.performDrop(sender) ?? false
    }
}
