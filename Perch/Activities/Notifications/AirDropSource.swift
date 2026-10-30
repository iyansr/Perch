import AppKit
import ApplicationServices
import Contacts
import SwiftUI
import UniformTypeIdentifiers

/// An incoming AirDrop as far as its notification says.
nonisolated struct AirDropRequest: Equatable {
    /// `req.iden` of the notification, else `rec-<rowID>`.
    let transferID: String
    let sender: String
    /// A file name (`IMG_0042.jpg`) or a description (`3 photos`); empty when the text names neither.
    let file: String
}

/// Reads the text of a `com.apple.sharingd` notification.
///
/// UNVERIFIED against a real transfer: no AirDrop could be triggered while building this. The parser
/// relies on the English sentence the banner uses, `<sender> would like to share <file>` (also `wants
/// to share`, `is trying to send`, optional `with you`, quotes and trailing period tolerated), found in the
/// body, subtitle or title. When no such sentence is found it falls back to "title is the sender, body
/// is the file", dropping a line that just says "AirDrop". Notifications that report an outcome
/// (received, saved, declined, cancelled, failed) are ignored. Other languages take the fallback.
nonisolated enum AirDropParser {
    static let bundleID = "com.apple.sharingd"

    private static let sentence = try! NSRegularExpression(
        pattern: #"^(?<sender>.+?)\s+(?:would like to|wants to|want to|is trying to|would like you to accept)\s+(?:share|send)\s+(?<file>.+?)(?:\s+with you)?\s*[.!]?$"#,
        options: [.caseInsensitive]
    )
    private static let outcome = try! NSRegularExpression(
        pattern: #"\b(received|saved|accepted|declined|cancell?ed|failed|completed|finished|was sent)\b"#,
        options: [.caseInsensitive]
    )

    static func request(from record: NotificationRecord) -> AirDropRequest? {
        guard record.bundleID == bundleID else { return nil }
        let title = trim(record.title), subtitle = trim(record.subtitle), body = trim(record.body)
        let transferID = record.identifier.flatMap { $0.isEmpty ? nil : $0 } ?? "rec-\(record.rowID)"
        let lines = [title, subtitle, body].filter { !$0.isEmpty }

        for text in [body, subtitle, title, lines.joined(separator: " ")] where !text.isEmpty {
            if let (sender, file) = split(text) {
                return AirDropRequest(transferID: transferID, sender: sender, file: file)
            }
        }
        if lines.contains(where: { matches(outcome, $0) }) { return nil }

        let content = lines.filter { $0.caseInsensitiveCompare("AirDrop") != .orderedSame }
        switch content.count {
        case 0: return nil
        case 1: return AirDropRequest(transferID: transferID, sender: "Someone", file: unquote(content[0]))
        default: return AirDropRequest(transferID: transferID, sender: unquote(content[0]), file: unquote(content.dropFirst().joined(separator: " ")))
        }
    }

    /// Names to look up in Contacts: the sender as written, and the owner of a device name (`Alice's iPhone` → `Alice`).
    static func contactNames(for sender: String) -> [String] {
        var names = [sender]
        if let range = sender.range(of: #"^(.+?)[’']s\s+\S.*$"#, options: .regularExpression) {
            let owner = sender[range].components(separatedBy: CharacterSet(charactersIn: "’'")).first ?? ""
            if !owner.isEmpty { names.append(owner.trimmingCharacters(in: .whitespaces)) }
        }
        return names
    }

    /// Case- and accent-insensitive; Contacts' fuzzy name search also returns partial matches, which must not get an avatar.
    static func namesMatch(_ lhs: String, _ rhs: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return !lhs.isEmpty && lhs.compare(rhs, options: options) == .orderedSame
    }

    /// The icon's content type: from the extension when the file is named, else from the description.
    static func fileType(for file: String) -> UTType {
        let ext = (file as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) { return type }
        let text = file.lowercased()
        let table: [(words: [String], type: UTType)] = [
            (["photo", "image", "picture"], .image),
            (["video", "movie"], .movie),
            (["contact"], .vCard),
            (["link", "website", "url"], .url),
            (["audio", "song", "voice"], .audio),
            (["document", "pdf"], .pdf),
            (["folder"], .folder),
        ]
        return table.first { entry in entry.words.contains { text.contains($0) } }?.type ?? .data
    }

    private static func split(_ text: String) -> (sender: String, file: String)? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = sentence.firstMatch(in: text, range: range),
              let sender = Range(match.range(withName: "sender"), in: text),
              let file = Range(match.range(withName: "file"), in: text)
        else { return nil }
        let senderText = unquote(String(text[sender]))
        return senderText.isEmpty ? nil : (senderText, unquote(String(text[file])))
    }

    private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func trim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func unquote(_ text: String) -> String {
        var result = trim(text)
        let quotes = CharacterSet(charactersIn: "“”\"‘'«»")
        while let first = result.unicodeScalars.first, quotes.contains(first) { result.removeFirst() }
        while let last = result.unicodeScalars.last, quotes.contains(last) || last == "." { result.removeLast() }
        return trim(result)
    }
}

/// Presses Accept or Decline on the AirDrop banner through the Notification Center process's accessibility tree.
///
/// UNVERIFIED: the button names and the tree shape are inferences (see plan C5). The search is
/// defensive: it walks every window of `com.apple.notificationcenterui` (depth and size bounded) and
/// accepts a button whose title or description is the word, or an accessibility action named for it
/// (macOS 13+ exposes banner buttons as custom actions called `Name:Accept…`). The label match is English.
nonisolated enum AirDropBanner {
    enum Choice: String {
        case accept = "Accept"
        case decline = "Decline"
    }

    enum Outcome: Equatable {
        case pressed
        case notTrusted
        case noBanner
        case buttonNotFound
    }

    static let bundleID = "com.apple.notificationcenterui"
    private static let maxDepth = 14
    private static let maxElements = 600

    /// Whether an accessibility label (title, description or value) names `choice`.
    static func matches(label: String, _ choice: Choice) -> Bool {
        label.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(choice.rawValue) == .orderedSame
    }

    /// The custom action for `choice` among `names`, e.g. `Name:Accept\nTarget:0x0\nSelector:(null)`.
    static func actionName(in names: [String], for choice: Choice) -> String? {
        names.first { name in
            guard name.hasPrefix("Name:") else { return matches(label: name, choice) }
            let label = name.dropFirst("Name:".count).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return matches(label: label, choice)
        }
    }

    /// Of several banners, prefers the button whose surroundings mention `hints` (sender, file name).
    static func pick<T>(from candidates: [(element: T, context: String)], hints: [String]) -> T? {
        let wanted = hints.map { $0.lowercased() }.filter { !$0.isEmpty }
        if let hit = candidates.first(where: { candidate in wanted.contains { candidate.context.lowercased().contains($0) } }) {
            return hit.element
        }
        return candidates.first?.element
    }

    static func press(_ choice: Choice, hints: [String]) -> Outcome {
        guard AXIsProcessTrusted() else { return .notTrusted }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return .noBanner }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 1)

        var found: [(element: Match, context: String)] = []
        var visited = 0
        let windows = children(of: root, attribute: kAXWindowsAttribute)
        if windows.isEmpty { return .noBanner }
        for window in windows {
            walk(window, choice, depth: 0, visited: &visited, found: &found)
        }
        guard let match = pick(from: found, hints: hints) else { return .buttonNotFound }
        let result: AXError
        switch match.action {
        case .press:
            result = AXUIElementPerformAction(match.element, kAXPressAction as CFString)
        case .custom(let name):
            result = AXUIElementPerformAction(match.element, name as CFString)
        }
        return result == .success ? .pressed : .buttonNotFound
    }

    private struct Match {
        enum Action { case press, custom(String) }
        let element: AXUIElement
        let action: Action
    }

    /// `context` is the text of the closest ancestor's subtree (the banner), to tell banners apart.
    private static func walk(_ element: AXUIElement, _ choice: Choice, depth: Int, visited: inout Int, found: inout [(element: Match, context: String)], parents: [AXUIElement] = []) {
        guard depth < maxDepth, visited < maxElements else { return }
        visited += 1

        let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap { string(element, $0) }
        let role = string(element, kAXRoleAttribute)
        let actions = actionNames(of: element)
        let context = { parents.suffix(3).first.map { texts(in: $0, depth: 0).joined(separator: " ") } ?? "" }

        if let name = actionName(in: actions.filter { $0 != kAXPressAction }, for: choice) {
            found.append((Match(element: element, action: .custom(name)), context()))
        } else if role == kAXButtonRole, labels.contains(where: { matches(label: $0, choice) }) {
            found.append((Match(element: element, action: .press), context()))
        }
        for child in children(of: element, attribute: kAXChildrenAttribute) {
            walk(child, choice, depth: depth + 1, visited: &visited, found: &found, parents: parents + [element])
        }
    }

    private static func texts(in element: AXUIElement, depth: Int) -> [String] {
        guard depth < 5 else { return [] }
        var result = [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute].compactMap { string(element, $0) }
        for child in children(of: element, attribute: kAXChildrenAttribute) { result += texts(in: child, depth: depth + 1) }
        return result
    }

    private static func children(of element: AXUIElement, attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func actionNames(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }
}

/// An incoming AirDrop in the island with Accept and Decline, which press the system banner's buttons.
///
/// Detection reads usernoted's database (Full Disk Access, see `NotificationDatabase`): the request
/// arrives as a `com.apple.sharingd` notification. Answering needs Accessibility, which onboarding
/// already asks for. The avatar comes from Contacts when the sender's name matches a contact
/// (Contacts access is requested when the source starts).
///
/// The activity ends when the notification leaves the database (answered on the Mac or the phone,
/// cancelled, timed out) or when Perch answers it. Only the system banner can be pressed: if it has
/// already slid away and Notification Center's list is closed, the buttons are not in the accessibility
/// tree and the card says so.
final class AirDropSource: ActivitySource {
    static let id = "airdrop"
    static let info = ActivitySourceInfo(
        title: "AirDrop (experimental)",
        detail: "Incoming AirDrops beside the notch: accept or decline from the island, and a card with Reveal in Finder when files arrive (including auto-accepted ones from your own devices). Asking needs Full Disk Access; answering also uses Accessibility.",
        symbol: "dot.radiowaves.up.forward",
        tint: .blue,
        permission: .fullDiskAccess
    )

    private static let owner = "airdrop"

    private struct Pending {
        let activityID: UUID
        let rowID: Int64
        let request: AirDropRequest
    }

    private weak var center: ActivityCenter?
    private var pending: [String: Pending] = [:]
    /// The card answered with Accept; the files that then arrive attach to it instead of a second card.
    private var lastAccepted: (activityID: UUID, at: Date)?
    private lazy var arrivals = AirDropArrivals { [weak self] transfer in self?.received(transfer) }

    func start(center: ActivityCenter) {
        self.center = center
        if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
            CNContactStore().requestAccess(for: .contacts) { _, _ in }
        }
        DecisionRouter.shared.register(owner: Self.owner) { [weak self] id, accepted in
            self?.answer(transferID: id, accepted: accepted)
        }
        NotificationFeed.shared.subscribe(Self.owner) { [weak self] update in
            self?.receive(update)
        }
        // Needs no Full Disk Access: auto-accepted transfers show even when the database is unreadable.
        arrivals.start()
    }

    func stop() {
        NotificationFeed.shared.unsubscribe(Self.owner)
        arrivals.stop()
        lastAccepted = nil
        DecisionRouter.shared.unregister(owner: Self.owner)
        for item in pending.values { center?.dismiss(item.activityID) }
        pending = [:]
        center = nil
    }

    // MARK: Incoming

    private func receive(_ update: NotificationFeed.Update) {
        for record in update.records {
            guard let request = AirDropParser.request(from: record), pending[request.transferID] == nil else { continue }
            begin(request, rowID: record.rowID)
        }
        for rowID in update.removed {
            guard let entry = pending.first(where: { $0.value.rowID == rowID }) else { continue }
            pending[entry.key] = nil
            center?.dismiss(entry.value.activityID)
        }
    }

    private func begin(_ request: AirDropRequest, rowID: Int64) {
        guard let center else { return }
        let id = UUID()
        pending[request.transferID] = Pending(activityID: id, rowID: rowID, request: request)
        NotificationFeed.shared.track(rowID)

        center.upsert(
            id: id,
            kind: .airdrop(transferID: request.transferID),
            symbol: Self.info.symbol,
            title: "From \(request.sender)",
            detail: request.file,
            status: .needsAttention
        )
        let icon = NSWorkspace.shared.icon(for: AirDropParser.fileType(for: request.file))
        center.update(id) { activity in
            activity.image = icon
            activity.decision = PendingDecision(id: request.transferID, owner: Self.owner, declineTitle: "Decline", acceptTitle: "Accept")
        }
        loadAvatar(for: request.sender, activityID: id)
    }

    private func loadAvatar(for sender: String, activityID: UUID) {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return }
        Task { [weak self] in
            guard let avatar = await Self.avatar(for: sender) else { return }
            self?.center?.update(activityID) { $0.badgeImage = avatar }
        }
    }

    @concurrent private static func avatar(for sender: String) async -> NSImage? {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
        ]
        for name in AirDropParser.contactNames(for: sender) {
            let contacts = (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys)) ?? []
            let match = contacts.first { contact in
                contact.thumbnailImageData != nil
                    && AirDropParser.namesMatch(CNContactFormatter.string(from: contact, style: .fullName) ?? "", name)
            }
            if let data = match?.thumbnailImageData, let image = NSImage(data: data) { return image }
        }
        return nil
    }

    // MARK: Answering

    private func answer(transferID: String, accepted: Bool) {
        guard let entry = pending[transferID] else { return }
        let choice: AirDropBanner.Choice = accepted ? .accept : .decline
        let hints = [entry.request.sender, entry.request.file]
        Task { [weak self] in
            let outcome = await Self.press(choice, hints: hints)
            self?.finishAnswer(transferID: transferID, accepted: accepted, outcome: outcome)
        }
    }

    @concurrent private static func press(_ choice: AirDropBanner.Choice, hints: [String]) async -> AirDropBanner.Outcome {
        AirDropBanner.press(choice, hints: hints)
    }

    private func finishAnswer(transferID: String, accepted: Bool, outcome: AirDropBanner.Outcome) {
        guard let center, let entry = pending[transferID] else { return }
        switch outcome {
        case .pressed:
            pending[transferID] = nil
            NotificationFeed.shared.untrack(entry.rowID)
            if accepted {
                center.setDecision(entry.activityID, nil)
                center.update(entry.activityID) { $0.detail = "Accepted · \(entry.request.file)" }
                center.finish(entry.activityID, status: .done)
                lastAccepted = (entry.activityID, Date())
            } else {
                center.dismiss(entry.activityID)
            }
        case .notTrusted:
            fail(entry, "Allow Accessibility for Perch to answer AirDrop")
            AccessibilityPermission.openSystemSettings()
        case .noBanner, .buttonNotFound:
            fail(entry, "Couldn't find the AirDrop banner; answer it in Notification Center")
        }
    }

    /// The decision stays, so the user can retry or answer elsewhere; the record leaving the database ends the card.
    private func fail(_ entry: Pending, _ message: String) {
        center?.update(entry.activityID) { $0.detail = message }
    }

    // MARK: Arrived

    /// Files AirDrop saved: attach them to the card the user just accepted, or show the arrival on its own
    /// (auto-accepted transfers never asked). The card offers Reveal in Finder.
    private func received(_ transfer: AirDropArrivals.Transfer) {
        guard let center, let first = transfer.files.first else { return }
        let detail = transfer.files.count == 1 ? first.lastPathComponent : "\(transfer.files.count) files"
        if let lastAccepted, Date().timeIntervalSince(lastAccepted.at) < AirDropArrivals.freshness,
           center.items.contains(where: { $0.id == lastAccepted.activityID }) {
            center.update(lastAccepted.activityID) { activity in
                activity.outputs = transfer.files
                activity.detail = "Received · \(detail)"
            }
            self.lastAccepted = nil
            return
        }
        let id = UUID()
        var activity = Activity(
            id: id, kind: .airdrop(transferID: transfer.key), symbol: Self.info.symbol, title: "AirDrop received",
            detail: detail, status: .running, progress: .indeterminate, updatedAt: Date()
        )
        activity.outputs = transfer.files
        activity.image = NSWorkspace.shared.icon(forFile: first.path)
        center.show(activity)
        center.finish(id, status: .done)
    }
}
