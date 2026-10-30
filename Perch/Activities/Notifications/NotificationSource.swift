import AppKit
import SwiftUI

/// Where a reply to a Messages notification goes, from whatever the notification carries.
nonisolated struct MessageReplyTarget: Equatable {
    /// `iMessage;-;+15551234567`; the exact chat, when the payload has one.
    var chatGUID: String?
    /// `+15551234567`, an e-mail address or `chat123…`; matched against the end of each chat's id.
    var chatIdentifier: String?
    /// The notification title (the contact's name for a one-to-one message): last resort.
    var contactName: String?
}

/// Pure mapping from a Messages notification record to what the island shows and where a reply goes.
nonisolated enum MessagesNotification {
    static let bundleID = "com.apple.MobileSMS"

    /// Sender and text, or nil when the notification has neither (a stray empty banner).
    /// A group message carries the group name as subtitle; it leads the detail line.
    static func content(of record: NotificationRecord) -> (sender: String, text: String)? {
        let sender = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = record.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = record.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sender.isEmpty || !body.isEmpty else { return nil }
        return (sender.isEmpty ? "Messages" : sender, group.isEmpty ? body : "\(group): \(body)")
    }

    static func replyTarget(of record: NotificationRecord) -> MessageReplyTarget {
        MessageReplyTarget(
            chatGUID: record.chatGUID,
            chatIdentifier: record.chatIdentifier,
            contactName: record.title.isEmpty ? nil : record.title
        )
    }

    /// `imessage://<address>` opens the conversation for a phone number or e-mail address.
    static func conversationURL(for target: MessageReplyTarget) -> URL? {
        guard let identifier = target.chatIdentifier, !identifier.hasPrefix("chat"),
              let escaped = identifier.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)
        else { return nil }
        return URL(string: "imessage://\(escaped)")
    }

    // MARK: Reply

    static let openActionID = "open"

    /// Passed to `osascript` as `argv`, so message text never touches the script source.
    static func replyArguments(text: String, target: MessageReplyTarget) -> [String] {
        [text, target.chatGUID ?? "", target.chatIdentifier ?? "", target.contactName ?? ""]
    }

    /// Order of attempts: the chat's GUID; a chat whose id ends in the identifier (one-to-one `;-;`, then group `;+;`);
    /// a participant with the notification's title as name. Each later attempt is a guess about a
    /// payload that Apple does not document; the script reports which one worked.
    static let replyScript = """
    on run argv
        set theText to item 1 of argv
        set theGUID to item 2 of argv
        set theIdentifier to item 3 of argv
        set theName to item 4 of argv
        tell application "Messages"
            if theGUID is not "" then
                send theText to chat id theGUID
                return "guid"
            end if
            if theIdentifier is not "" then
                set directSuffix to ";-;" & theIdentifier
                set groupSuffix to ";+;" & theIdentifier
                try
                    send theText to (first chat whose id ends with directSuffix)
                    return "identifier"
                end try
                try
                    send theText to (first chat whose id ends with groupSuffix)
                    return "identifier"
                end try
            end if
            if theName is not "" then
                send theText to (first participant whose name is theName)
                return "name"
            end if
        end tell
        error "The notification does not say which chat it belongs to."
    end run
    """

    /// A sentence for the card when `osascript` fails.
    static func failureMessage(stderr: String) -> String {
        let text = stderr.lowercased()
        if stderr.contains("-1743") || text.contains("not authorized") {
            return "Allow Perch to control Messages in Privacy & Security → Automation"
        }
        if text.contains("does not say which chat") {
            return "Couldn't tell which chat this was"
        }
        if stderr.contains("-1728") || text.contains("can't get") {
            return "Couldn't find that chat in Messages"
        }
        return "Couldn't send the reply"
    }
}

/// Mirrors Messages notifications into the island with Open and quick Reply.
///
/// Reads usernoted's database (Full Disk Access), see `NotificationDatabase`. Messages only, labelled
/// experimental: the schema and the payload keys are undocumented and have moved between macOS releases.
///
/// Reply limits: the notification carries the sender's display name as title and, if Messages stored
/// one, a chat identifier in its user info. Replying uses the chat GUID if found, then a chat whose id
/// ends in the identifier, then a participant with that exact name. Two contacts with the same name, or a
/// group message without any identifier, cannot be told apart; the reply then fails with a message rather than guessing.
final class NotificationSource: ActivitySource {
    static let id = "notifications"
    static let info = ActivitySourceInfo(
        title: "Message Notifications (experimental)",
        detail: "Shows new Messages in the island with Open and a quick reply. Reads the system notification database, so it needs Full Disk Access.",
        symbol: "message.fill",
        tint: .green,
        permission: .fullDiskAccess
    )

    private static let owner = "notifications"
    private static let transient = Activity.Presentation.transient(.seconds(6))
    private static let rememberedTargets = 30

    private weak var center: ActivityCenter?
    private var targets: [String: MessageReplyTarget] = [:]
    private var order: [String] = []
    private var icon: NSImage?

    func start(center: ActivityCenter) {
        self.center = center
        icon = Self.messagesIcon()
        ActionRouter.shared.register(owner: Self.owner, ActionRouter.Handler(
            perform: { [weak self] activity, actionID in self?.perform(actionID, on: activity) },
            reply: { [weak self] activity, text in self?.reply(text, to: activity) }
        ))
        NotificationFeed.shared.subscribe(Self.owner) { [weak self] update in
            self?.receive(update.records)
        }
    }

    func stop() {
        NotificationFeed.shared.unsubscribe(Self.owner)
        ActionRouter.shared.unregister(owner: Self.owner)
        for id in order { dismiss(noteID: id) }
        targets = [:]
        order = []
        center = nil
    }

    // MARK: Incoming

    private func receive(_ records: [NotificationRecord]) {
        guard let center else { return }
        for record in records where record.bundleID == MessagesNotification.bundleID {
            guard let activity = Self.activity(for: record, icon: icon) else { continue }
            remember(MessagesNotification.replyTarget(of: record), for: String(record.rowID))
            center.flash(activity)
        }
    }

    static func activity(for record: NotificationRecord, icon: NSImage?, id: UUID = UUID(), now: Date = Date()) -> Activity? {
        guard let content = MessagesNotification.content(of: record) else { return nil }
        var activity = Activity(
            id: id,
            kind: .notification(id: String(record.rowID), bundleID: record.bundleID),
            symbol: "message.fill",
            title: content.sender,
            detail: content.text,
            status: .running,
            progress: .indeterminate,
            updatedAt: now,
            presentation: transient
        )
        activity.image = icon
        activity.replyPlaceholder = "Reply"
        activity.actions = [ActivityAction(id: MessagesNotification.openActionID, title: "Open", symbol: "arrow.up.forward.app")]
        return activity
    }

    private func remember(_ target: MessageReplyTarget, for noteID: String) {
        targets[noteID] = target
        order.append(noteID)
        while order.count > Self.rememberedTargets { targets[order.removeFirst()] = nil }
    }

    private func dismiss(noteID: String) {
        guard let center else { return }
        for item in center.items {
            if case let .notification(id, _) = item.kind, id == noteID { center.dismiss(item.id) }
        }
    }

    // MARK: Actions

    private func noteID(of activity: Activity) -> String? {
        if case let .notification(id, _) = activity.kind { id } else { nil }
    }

    private func perform(_ actionID: String, on activity: Activity) {
        guard actionID == MessagesNotification.openActionID else { return }
        if let id = noteID(of: activity), let target = targets[id], let url = MessagesNotification.conversationURL(for: target) {
            NSWorkspace.shared.open(url)
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MessagesNotification.bundleID) {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
        center?.dismiss(activity.id)
    }

    private func reply(_ text: String, to activity: Activity) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let id = noteID(of: activity), let target = targets[id] else { return }
        let arguments = MessagesNotification.replyArguments(text: text, target: target)
        let activityID = activity.id
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.runOSAScript(MessagesNotification.replyScript, arguments: arguments)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let center = self?.center else { return }
                    switch result {
                    case .success:
                        center.dismiss(activityID)
                    case .failure(let error):
                        center.update(activityID) { $0.detail = MessagesNotification.failureMessage(stderr: error.stderr) }
                    }
                }
            }
        }
    }

    private struct ScriptError: Error { let stderr: String }

    /// `osascript` rather than `NSAppleScript`, which must stay on the main thread; `arguments` reach the script's `argv`.
    private nonisolated static func runOSAScript(_ script: String, arguments: [String]) -> Result<String, ScriptError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script] + arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return .failure(ScriptError(stderr: error.localizedDescription))
        }
        let stderrData = errors.fileHandleForReading.readDataToEndOfFile()
        let stdoutData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return .failure(ScriptError(stderr: String(decoding: stderrData, as: UTF8.self)))
        }
        return .success(String(decoding: stdoutData, as: UTF8.self))
    }

    private static func messagesIcon() -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: MessagesNotification.bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}
