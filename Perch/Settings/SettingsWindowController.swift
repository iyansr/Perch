import AppKit
import SwiftUI

/// The Settings window: a regular titled window, separate from the notch surface.
/// Created on demand and released on close, so its polling tasks stop with it.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private static let size = NSSize(width: 760, height: 560)
    private var window: NSWindow?

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        // Perch is an accessory app; without activating, the window opens behind the frontmost app.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Perch Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        let hosting = NSHostingController(rootView: SettingsView())
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.contentMinSize = NSSize(width: 680, height: 460)
        window.setContentSize(Self.size)
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
