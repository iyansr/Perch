import AppKit
import SwiftUI

/// Mute / camera / leave controls on the pill while a Zoom or Google Meet call is open.
///
/// Zoom: detected and driven through its Accessibility menu bar (`ZoomController`).
/// Meet: only when "Meet controls" is on; scripts the meeting tab of Chrome, Edge or Arc
/// (`MeetController`), which needs "Allow JavaScript from Apple Events" in the browser.
/// One 1 s timer runs while Zoom, or a browser with Meet controls on, is running; otherwise nothing polls.
final class CallSource: ActivitySource {
    static let id = "call"
    static let info = ActivitySourceInfo(
        title: "Call Controls",
        detail: "Mute, camera and leave buttons while a Zoom call is open. Google Meet in Chrome needs its own switch and “Allow JavaScript from Apple Events”.",
        symbol: "video.fill",
        tint: .blue,
        permission: .accessibility
    )

    private weak var center: ActivityCenter?
    private let zoom = ZoomController()
    private let meet = MeetController()
    private let zoomID = UUID()
    private let meetID = UUID()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var tick = 0
    private var meetPoll = MeetController.Poll.none

    func start(center: ActivityCenter) {
        self.center = center
        ActionRouter.shared.register(owner: "call", ActionRouter.Handler(perform: { [weak self] activity, actionID in
            self?.perform(activity, actionID)
        }))
        let notifications = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateTimer() }
            })
        }
        meet.resetDenials()
        updateTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
        ActionRouter.shared.unregister(owner: "call")
        center?.dismiss(zoomID)
        center?.dismiss(meetID)
    }

    // MARK: Polling

    private var meetEnabled: Bool { AppSettings.shared.meetControls }

    private func updateTimer() {
        let needed = zoom.app != nil || (meetEnabled && meet.anyBrowserRunning)
        if needed, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            poll()
        } else if !needed {
            timer?.invalidate()
            timer = nil
            meetPoll = .none
            render()
        }
    }

    private func poll() {
        tick += 1
        if meetEnabled {
            // Scripting a browser costs more than an AX read: every other second.
            if tick % 2 == 0 {
                meet.poll { [weak self] result in
                    self?.meetPoll = result
                    self?.render()
                }
            }
        } else if meetPoll != .none {
            meetPoll = .none
        }
        render()
        if zoom.app == nil, !(meetEnabled && meet.anyBrowserRunning) { updateTimer() }
    }

    // MARK: Activities

    private func render() {
        show(.zoom, id: zoomID, state: zoom.state(), disabledHint: nil)
        switch meetEnabled ? meetPoll : .none {
        case .none:
            show(.meet, id: meetID, state: nil, disabledHint: nil)
        case .call(_, let state):
            show(.meet, id: meetID, state: state, disabledHint: nil)
        case .javaScriptDisabled:
            show(.meet, id: meetID, state: nil, disabledHint: "Turn on Allow JavaScript from Apple Events in the browser’s Developer menu")
        }
    }

    private func show(_ app: Activity.CallApp, id: UUID, state: CallState?, disabledHint: String?) {
        guard let center else { return }
        let existing = center.items.first { $0.id == id }
        let title = app == .zoom ? "Zoom" : "Google Meet"
        let detail: String
        let actions: [ActivityAction]
        if let state {
            detail = CallLogic.detail(for: state)
            actions = CallLogic.actions(for: state)
        } else if let disabledHint {
            detail = disabledHint
            actions = []
        } else {
            if existing != nil { center.dismiss(id) }
            return
        }
        if let existing, existing.detail == detail, existing.actions == actions { return }
        center.show(Activity(
            id: id,
            kind: .call(app),
            symbol: "video.fill",
            title: title,
            detail: detail,
            status: .running,
            progress: .indeterminate,
            updatedAt: Date(),
            actions: actions
        ))
    }

    private func perform(_ activity: Activity, _ actionID: String) {
        guard case .call(let app) = activity.kind else { return }
        switch app {
        case .zoom: zoom.perform(actionID)
        case .meet: meet.perform(actionID)
        }
        // Show the new mute / camera state without waiting for the next tick.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.4))
            self?.tick = 1
            self?.poll()
        }
    }
}
