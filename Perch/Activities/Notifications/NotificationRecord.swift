import Foundation

/// One delivered notification, decoded from a row of usernoted's `record` table.
nonisolated struct NotificationRecord: Equatable {
    /// `record.rec_id`: grows with every delivered notification, so it doubles as a cursor.
    var rowID: Int64
    var bundleID: String
    /// The request identifier (`req.iden`); apps may reuse it to replace a notification.
    var identifier: String?
    var threadID: String?
    var title: String
    var subtitle: String
    var body: String
    var date: Date?
    /// A Messages chat GUID (`iMessage;-;+15551234567`) found anywhere in the payload, if any.
    var chatGUID: String?
    /// A value stored under a key containing "ChatIdentifier" (`+15551234567`, `chat123…`), if any.
    var chatIdentifier: String?
}

/// Decodes the binary plist in `record.data`.
///
/// Layout relied on (usernoted, macOS 13+; Apple documents none of it):
/// top-level dictionary with `app` (bundle ID), `date` (seconds since 2001) and `req`, the notification
/// request: `titl`, `subt`, `body`, `iden`, `thre` (thread), plus app-specific user info.
/// Every key is optional; a blob without a `req` dictionary is rejected.
nonisolated enum NotificationBlob {
    static func decode(_ data: Data, rowID: Int64, fallbackBundleID: String?) -> NotificationRecord? {
        guard let root = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let request = root["req"] as? [String: Any]
        else { return nil }

        let bundleID = (root["app"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackBundleID ?? ""
        guard !bundleID.isEmpty else { return nil }

        var scan = Scan()
        scan.walk(request)
        return NotificationRecord(
            rowID: rowID,
            bundleID: bundleID,
            identifier: string(request, "iden", "identifier"),
            threadID: string(request, "thre", "threadIdentifier"),
            title: string(request, "titl", "title") ?? "",
            subtitle: string(request, "subt", "subtitle") ?? "",
            body: string(request, "body", "message") ?? "",
            date: date(root["date"]) ?? date(request["date"]),
            chatGUID: scan.chatGUID,
            chatIdentifier: scan.chatIdentifier
        )
    }

    /// `service;-;address` (one-to-one) or `service;+;chat…` (group).
    static func isChatGUID(_ text: String) -> Bool {
        let parts = text.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
        return parts.count == 3 && (parts[1] == "-" || parts[1] == "+") && !parts[0].isEmpty && !parts[2].isEmpty
            && !text.contains(" ")
    }

    private static func string(_ dictionary: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String { return value }
        }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let seconds = value as? Double { return Date(timeIntervalSinceReferenceDate: seconds) }
        return nil
    }

    /// Looks through nested user info for the chat a Messages notification belongs to.
    private struct Scan {
        var chatGUID: String?
        var chatIdentifier: String?

        mutating func walk(_ value: Any, key: String = "", depth: Int = 0) {
            guard depth < 8 else { return }
            switch value {
            case let dictionary as [String: Any]:
                for (key, child) in dictionary.sorted(by: { $0.key < $1.key }) { walk(child, key: key, depth: depth + 1) }
            case let array as [Any]:
                for child in array { walk(child, key: key, depth: depth + 1) }
            case let text as String:
                if chatGUID == nil, NotificationBlob.isChatGUID(text) { chatGUID = text }
                if chatIdentifier == nil, !text.isEmpty, key.lowercased().contains("chatidentifier") { chatIdentifier = text }
            default:
                break
            }
        }
    }
}
