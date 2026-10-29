import AppKit

/// Agent app (LSUIElement): no Dock icon, no main menu. The notch surface is the whole UI.
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = NotchController(activities: ActivityCenter(), search: SearchEngine())
        controller.start()
        self.controller = controller
        ClipboardMonitor.shared.start()
    }
}
