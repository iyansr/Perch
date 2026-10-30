import Foundation
import SwiftUI

/// Maps agent events to one live activity per session.
final class AgentSessions {
    /// A session that sends nothing for this long is dropped.
    static let idleTimeout: TimeInterval = 30 * 60

    /// What an event does to its session's activity.
    enum Transition: Equatable {
        case status(Activity.Status)
        case dismiss
        /// Remember the session (terminal, cwd) without showing anything.
        case track
        case ignore
    }

    private struct Session {
        let activityID: UUID
        var lastSeen: Date
        /// The `perch event --await` request whose Allow / Deny card is showing on this session's row.
        var request: String?
        /// What the row shows, kept to flip its status after an answer.
        var event: AgentEvent?
    }

    private let activities: ActivityCenter
    private let now: () -> Date
    /// Delivers an Allow / Deny to the helper waiting on a request (`AgentBridge.reply`).
    var reply: (_ request: String, _ allow: Bool) -> Void
    private var sessions: [String: Session] = [:]
    private var pruneTimer: Timer?

    init(
        activities: ActivityCenter,
        now: @escaping () -> Date = Date.init,
        reply: @escaping (_ request: String, _ allow: Bool) -> Void = { _, _ in }
    ) {
        self.activities = activities
        self.now = now
        self.reply = reply
    }

    func startPruning() {
        pruneTimer?.invalidate()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pruneIdle() }
        }
    }

    /// Hook event → activity status (§2 of the plan). Claude Code and Codex share the event names.
    /// `session_start` only tracks the session: a freshly opened agent waiting for a prompt is not "running".
    static func transition(for event: AgentEvent) -> Transition {
        switch event.type {
        case "user_prompt_submit", "post_tool_use", "start": .status(.running)
        case "permission_request", "notification": .status(.needsAttention)
        case "stop", "interrupt": .status(.done)
        case "stop_failure": .status(.failed)
        case "exit": .status(event.exitCode == 0 ? .done : .failed)
        case "session_end": .dismiss
        case "session_start": .track
        default: .ignore
        }
    }

    static func title(for event: AgentEvent) -> String {
        let folder = event.cwd.map { URL(filePath: $0).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
        let name = event.source == .watch
            ? event.message?.split(separator: " ").first.map(String.init) ?? "Command"
            : event.source.displayName
        return [name, folder].compactMap(\.self).joined(separator: " · ")
    }

    /// Activity detail: the event text, or the exit summary for `perch watch`.
    static func detail(for event: AgentEvent) -> String? {
        guard event.type == "exit", let code = event.exitCode else { return event.message }
        let seconds = Int((event.duration ?? 0).rounded())
        let elapsed = seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
        return code == 0 ? "Finished in \(elapsed)" : "Exit \(code) after \(elapsed)"
    }

    func handle(_ event: AgentEvent) {
        guard event.v <= AgentEvent.currentVersion else { return }
        let key = "\(event.source.rawValue):\(event.session)"
        let transition = Self.transition(for: event)
        if transition == .ignore { return }

        if transition == .dismiss {
            if let session = sessions.removeValue(forKey: key) { activities.dismiss(session.activityID) }
            return
        }
        var session = sessions[key] ?? Session(activityID: UUID(), lastSeen: now())
        session.lastSeen = now()
        // Any later event means the agent moved on (answered in its terminal, or timed out and asked there):
        // the buttons would answer nothing. The row keeps its status.
        if session.request != nil {
            activities.setDecision(session.activityID, nil)
            session.request = nil
        }
        sessions[key] = session

        guard case let .status(status) = transition else { return }
        session.event = event
        sessions[key] = session
        show(session, status: status)
        if event.type == "permission_request", let request = event.request {
            sessions[key]?.request = request
            activities.setDecision(session.activityID, PendingDecision(id: request))
        }
    }

    /// The Allow / Deny card for `request` was answered: tell the waiting helper, drop the buttons and show the
    /// agent working again. Unknown or already-cleared requests do nothing.
    func answer(request: String, allow: Bool) {
        guard let (key, session) = sessions.first(where: { $0.value.request == request }) else { return }
        sessions[key]?.request = nil
        reply(request, allow)
        activities.setDecision(session.activityID, nil)
        show(session, status: .running, detail: allow ? "Allowed from Perch" : "Denied from Perch")
    }

    /// The helper waiting on `request` disconnected without an answer (its timeout, or the agent was answered in
    /// its terminal): drop the buttons. The row stays `needsAttention`: the agent still wants the user.
    func requestEnded(_ request: String) {
        guard let (key, session) = sessions.first(where: { $0.value.request == request }) else { return }
        sessions[key]?.request = nil
        activities.setDecision(session.activityID, nil)
    }

    private func show(_ session: Session, status: Activity.Status, detail: String? = nil) {
        guard let event = session.event else { return }
        activities.upsert(
            id: session.activityID,
            kind: .agent(source: event.source, sessionID: event.session),
            symbol: symbol(for: event.source),
            title: Self.title(for: event),
            detail: detail ?? Self.detail(for: event),
            status: status,
            terminal: event.term
        )
    }

    func pruneIdle() {
        let cutoff = now().addingTimeInterval(-Self.idleTimeout)
        for (key, session) in sessions where session.lastSeen < cutoff {
            sessions.removeValue(forKey: key)
            activities.dismiss(session.activityID)
        }
    }

    private func symbol(for source: AgentSource) -> String {
        switch source {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .watch: "terminal"
        }
    }
}

extension AgentSource {
    /// Brand mark asset (template-rendered); nil for sources without one.
    var logo: Image? {
        switch self {
        case .claude: Image("ClaudeLogo")
        case .codex: Image("OpenAILogo")
        case .watch: nil
        }
    }
}
