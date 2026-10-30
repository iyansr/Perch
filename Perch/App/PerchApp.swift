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
        let controller = NotchController(activities: activities, search: .shared)
        controller.start()
        self.controller = controller
        ClipboardMonitor.shared.start()
        // A test run hosts the app; it must not take over the socket of the Perch the user is running,
        // nor spawn media helpers and system listeners.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            startAgentBridge(activities: activities)
            ActivitySources.shared.start(center: activities)
        }
        AgentConnections.shared.refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        agentBridge?.stop()
        ActivitySources.shared.stopAll() // resumes Apple's HUD if Perch hid it
    }

    private func startAgentBridge(activities: ActivityCenter) {
        let sessions = AgentSessions(activities: activities)
        sessions.startPruning()
        let bridge = AgentBridge(
            onRequestEnded: { request in
                DispatchQueue.main.async { sessions.requestEnded(request) }
            },
            onEvent: { event in
                DispatchQueue.main.async { sessions.handle(event) }
            }
        )
        // Allow / Deny on a permission card: sessions flip the row, the bridge answers the waiting `perch event --await`.
        sessions.reply = { request, allow in bridge.reply(request: request, allow: allow) }
        DecisionRouter.shared.register(owner: "agent") { id, accepted in sessions.answer(request: id, allow: accepted) }
        do {
            try bridge.start()
        } catch {
            NSLog("Perch: agent socket unavailable: \(error)")
        }
        agentSessions = sessions
        agentBridge = bridge
    }
}
