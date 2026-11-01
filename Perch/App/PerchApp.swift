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
            UpdateController.shared.start(
                canPresent: { [weak self] in
                    guard let self, let model = self.controller?.model else { return false }
                    return model.state == .idle && !model.isReplying
                        && NSApp.keyWindow == nil && self.updateBlockReason(activities: activities) == nil
                },
                installationBlockReason: { [weak self] in
                    self?.updateBlockReason(activities: activities)
                }
            )
        }
        AgentConnections.shared.refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        UpdateController.shared.stop()
        agentBridge?.stop()
        ActivitySources.shared.stopAll() // resumes Apple's HUD if Perch hid it
    }

    private func updateBlockReason(activities: ActivityCenter) -> String? {
        if agentBridge?.hasPendingRequests == true {
            return "Answer the pending agent permission request before restarting Perch."
        }
        if ShortcutRecorderView.isRecordingShortcut {
            return "Finish recording your shortcut before restarting Perch."
        }
        if NSApp.modalWindow != nil || controller?.model.isReplying == true {
            return "Finish the open dialog or reply before restarting Perch."
        }
        if let state = controller?.model.state, state != .idle && state != .glance {
            return "Close the notch panel before restarting Perch."
        }
        for activity in activities.items where activity.status == .running || activity.status == .needsAttention {
            switch activity.kind {
            case .conversion:
                return "Wait for image conversion to finish before restarting Perch."
            case .dictation:
                return "Finish dictation before restarting Perch."
            case .timer:
                return "Finish or cancel your timer before restarting Perch."
            default:
                break
            }
        }
        return nil
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
        // A permission card's answer: sessions flip the row, the bridge answers the waiting `perch event --await`.
        sessions.reply = { request, response in
            switch response {
            case .allow: bridge.reply(request: request, allow: true)
            case .deny: bridge.reply(request: request, allow: false)
            case let .answer(option): bridge.reply(request: request, allow: true, answer: option)
            case .handBack: bridge.release(request: request)
            }
        }
        DecisionRouter.shared.register(owner: "agent") { id, answer in sessions.answer(request: id, answer) }
        do {
            try bridge.start()
        } catch {
            NSLog("Perch: agent socket unavailable: \(error)")
        }
        agentSessions = sessions
        agentBridge = bridge
    }
}
