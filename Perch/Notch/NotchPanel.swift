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

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Borderless windows must be allowed to overlap the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
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
