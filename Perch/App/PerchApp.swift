import AppKit

/// Agent app (LSUIElement): no Dock icon, no main menu. The notch surface is the whole UI.
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?
    private var agentSessions: AgentSessions?
    private var agentBridge: AgentBridge?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let activities = ActivityCenter()
        let controller = NotchController(activities: activities, search: SearchEngine())
        controller.start()
        self.controller = controller
        ClipboardMonitor.shared.start()
        // A test run hosts the app; it must not take over the socket of the Perch the user is running.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            startAgentBridge(activities: activities)
        }
        AgentConnections.shared.refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        agentBridge?.stop()
    }

    private func startAgentBridge(activities: ActivityCenter) {
        let sessions = AgentSessions(activities: activities)
        sessions.startPruning()
        let bridge = AgentBridge { event in
            DispatchQueue.main.async { MainActor.assumeIsolated { sessions.handle(event) } }
        }
        do {
            try bridge.start()
        } catch {
            NSLog("Perch: agent socket unavailable: \(error)")
        }
        agentSessions = sessions
        agentBridge = bridge
    }
}
