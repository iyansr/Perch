import Foundation
import SQLite3
import Testing
import UniformTypeIdentifiers
@testable import Perch

private final class FixtureToken {}

/// The `notif-synthetic-*.plist` fixtures are hand-built to the layout `NotificationBlob` documents;
/// none was captured from a real Mac (this machine has no Full Disk Access for Perch's tests).
private func blob(_ name: String) throws -> Data {
    let url = try #require(Bundle(for: FixtureToken.self).url(forResource: name, withExtension: "plist"))
    return try Data(contentsOf: url)
}

private func record(_ name: String, rowID: Int64 = 1) throws -> NotificationRecord {
    try #require(NotificationBlob.decode(try blob(name), rowID: rowID, fallbackBundleID: nil))
}

private func note(bundleID: String = "com.apple.sharingd", title: String = "", subtitle: String = "", body: String = "", rowID: Int64 = 7) -> NotificationRecord {
    NotificationRecord(rowID: rowID, bundleID: bundleID, identifier: nil, threadID: nil, title: title, subtitle: subtitle, body: body, date: nil, chatGUID: nil, chatIdentifier: nil)
}

struct NotificationBlobTests {
    @Test func directMessageFieldsAndChatIdentifier() throws {
        let record = try record("notif-synthetic-messages-direct", rowID: 42)
        #expect(record.rowID == 42)
        #expect(record.bundleID == "com.apple.MobileSMS")
        #expect(record.title == "Alice Example")
        #expect(record.body == "Are you free for lunch?")
        #expect(record.identifier == "11111111-2222-3333-4444-555555555555")
        #expect(record.threadID == "thread-alice")
        #expect(record.chatIdentifier == "+15555550123")
        #expect(record.chatGUID == nil)
        #expect(record.date == ISO8601DateFormatter().date(from: "2026-10-30T09:15:00Z"))
    }

    @Test func groupMessageFindsChatGUIDInNestedUserInfo() throws {
        let record = try record("notif-synthetic-messages-group")
        #expect(record.subtitle == "Climbing crew")
        #expect(record.chatGUID == "iMessage;+;chat000000000000000001")
    }

    @Test func bundleIDFallsBackToTheJoinedAppRow() throws {
        let data = try blob("notif-synthetic-malformed")
        #expect(NotificationBlob.decode(data, rowID: 1, fallbackBundleID: "com.apple.MobileSMS") == nil) // no `req`
        #expect(NotificationBlob.decode(Data("not a plist".utf8), rowID: 1, fallbackBundleID: "x") == nil)
    }

    @Test func chatGUIDShape() {
        #expect(NotificationBlob.isChatGUID("iMessage;-;+15555550123"))
        #expect(NotificationBlob.isChatGUID("SMS;+;chat123"))
        #expect(!NotificationBlob.isChatGUID("hello; world"))
        #expect(!NotificationBlob.isChatGUID("a;b;c"))
        #expect(!NotificationBlob.isChatGUID("iMessage;-;"))
    }
}

struct MessagesNotificationTests {
    @Test func activityCarriesSenderTextIconReplyAndOpen() throws {
        let record = try record("notif-synthetic-messages-direct", rowID: 9)
        let activity = try #require(NotificationSource.activity(for: record, icon: nil))
        #expect(activity.kind == .notification(id: "9", bundleID: "com.apple.MobileSMS"))
        #expect(activity.kind.owner == "notifications")
        #expect(activity.title == "Alice Example")
        #expect(activity.detail == "Are you free for lunch?")
        #expect(activity.presentation == .transient(.seconds(6)))
        #expect(activity.replyPlaceholder == "Reply")
        #expect(activity.actions.map(\.id) == ["open"])
    }

    @Test func groupMessageLeadsWithTheGroupName() throws {
        let content = try #require(MessagesNotification.content(of: try record("notif-synthetic-messages-group")))
        #expect(content.sender == "Bob Example")
        #expect(content.text == "Climbing crew: Saturday works")
    }

    @Test func emptyNotificationIsDropped() {
        #expect(MessagesNotification.content(of: note(bundleID: "com.apple.MobileSMS", title: " ", body: "")) == nil)
        #expect(NotificationSource.activity(for: note(bundleID: "com.apple.MobileSMS"), icon: nil) == nil)
    }

    @Test func replyTargetPrefersTheChatIdentifiersTheNotificationCarries() throws {
        let direct = MessagesNotification.replyTarget(of: try record("notif-synthetic-messages-direct"))
        #expect(direct == MessageReplyTarget(chatGUID: nil, chatIdentifier: "+15555550123", contactName: "Alice Example"))
        #expect(MessagesNotification.replyArguments(text: "yes", target: direct) == ["yes", "", "+15555550123", "Alice Example"])

        let group = MessagesNotification.replyTarget(of: try record("notif-synthetic-messages-group"))
        #expect(MessagesNotification.replyArguments(text: "ok", target: group)[1] == "iMessage;+;chat000000000000000001")
    }

    @Test func conversationURLOnlyForAddressesNotGroupChats() {
        #expect(MessagesNotification.conversationURL(for: MessageReplyTarget(chatIdentifier: "+15555550123"))?.absoluteString == "imessage://+15555550123")
        #expect(MessagesNotification.conversationURL(for: MessageReplyTarget(chatIdentifier: "chat000123")) == nil)
        #expect(MessagesNotification.conversationURL(for: MessageReplyTarget(contactName: "Alice")) == nil)
    }

    @Test func scriptFailuresBecomeSentences() {
        #expect(MessagesNotification.failureMessage(stderr: "execution error: Not authorized to send Apple events to Messages. (-1743)").contains("Automation"))
        #expect(MessagesNotification.failureMessage(stderr: "execution error: The notification does not say which chat it belongs to. (-2700)").contains("which chat"))
        #expect(MessagesNotification.failureMessage(stderr: "execution error: Messages got an error: Can’t get participant 1 whose name = \"x\". (-1728)").contains("find that chat"))
        #expect(MessagesNotification.failureMessage(stderr: "boom") == "Couldn't send the reply")
    }
}

struct AirDropParserTests {
    @Test func parsesTheFixtureNotification() throws {
        let request = try #require(AirDropParser.request(from: try record("notif-synthetic-airdrop")))
        #expect(request.transferID == "airdrop-transfer-1")
        #expect(request.sender == "Carol’s iPhone")
        #expect(request.file == "IMG_0042.jpg")
    }

    @Test(arguments: [
        ("Alice would like to share “Report.pdf”.", "Alice", "Report.pdf"),
        ("“Alice” wants to share 3 photos with you", "Alice", "3 photos"),
        ("Bob's MacBook Pro is trying to send a document.", "Bob's MacBook Pro", "a document"),
    ])
    func sentenceFormsInTheBody(body: String, sender: String, file: String) throws {
        let request = try #require(AirDropParser.request(from: note(title: "AirDrop", body: body)))
        #expect(request.sender == sender)
        #expect(request.file == file)
    }

    @Test func titleAndBodyFallbackWhenNoSentenceMatches() throws {
        let request = try #require(AirDropParser.request(from: note(title: "Dana", body: "Wochenplan.numbers")))
        #expect(request.sender == "Dana")
        #expect(request.file == "Wochenplan.numbers")
        #expect(request.transferID == "rec-7")
    }

    @Test func outcomeNotificationsAreNotRequests() {
        #expect(AirDropParser.request(from: note(title: "AirDrop", body: "Received “IMG_0042.jpg” from Carol")) == nil)
        #expect(AirDropParser.request(from: note(title: "AirDrop", body: "Saved to Downloads")) == nil)
        #expect(AirDropParser.request(from: note(title: "AirDrop", body: "Transfer was declined")) == nil)
        #expect(AirDropParser.request(from: note(title: "AirDrop")) == nil)
        #expect(AirDropParser.request(from: note(bundleID: "com.apple.MobileSMS", body: "Alice would like to share “x”")) == nil)
    }

    @Test func contactLookupNames() {
        #expect(AirDropParser.contactNames(for: "Carol Example") == ["Carol Example"])
        #expect(AirDropParser.contactNames(for: "Carol’s iPhone") == ["Carol’s iPhone", "Carol"])
        #expect(AirDropParser.contactNames(for: "Dan's MacBook Pro") == ["Dan's MacBook Pro", "Dan"])
        #expect(AirDropParser.namesMatch("carol example", "Carol Example"))
        #expect(AirDropParser.namesMatch("José", "jose"))
        #expect(!AirDropParser.namesMatch("iPhone Repair", "iPhone"))
        #expect(!AirDropParser.namesMatch("", ""))
    }

    @Test func fileTypeFromExtensionThenDescription() {
        #expect(AirDropParser.fileType(for: "IMG_0042.jpg").conforms(to: .image))
        #expect(AirDropParser.fileType(for: "Report.pdf") == .pdf)
        #expect(AirDropParser.fileType(for: "3 photos").conforms(to: .image))
        #expect(AirDropParser.fileType(for: "a video").conforms(to: .movie))
        #expect(AirDropParser.fileType(for: "a link").conforms(to: .url))
        #expect(AirDropParser.fileType(for: "something") == .data)
    }
}

struct AirDropBannerTests {
    @Test func labelMatching() {
        #expect(AirDropBanner.matches(label: "Accept", .accept))
        #expect(AirDropBanner.matches(label: " decline ", .decline))
        #expect(!AirDropBanner.matches(label: "Accept all", .accept))
        #expect(!AirDropBanner.matches(label: "Decline", .accept))
    }

    @Test func customActionNames() {
        let names = ["AXPress", "Name:Decline\nTarget:0x0\nSelector:(null)", "Name:Accept\nTarget:0x0\nSelector:(null)", "AXScrollToVisible"]
        #expect(AirDropBanner.actionName(in: names, for: .accept) == "Name:Accept\nTarget:0x0\nSelector:(null)")
        #expect(AirDropBanner.actionName(in: names, for: .decline) == "Name:Decline\nTarget:0x0\nSelector:(null)")
        #expect(AirDropBanner.actionName(in: ["AXPress", "Name:Open\nTarget:0x0"], for: .accept) == nil)
    }

    @Test func bannerWhoseTextMentionsTheSenderWins() {
        let candidates = [(element: "first", context: "AirDrop Dana wants to share x"), (element: "second", context: "AirDrop Carol would like to share IMG_0042.jpg")]
        #expect(AirDropBanner.pick(from: candidates, hints: ["Carol", "IMG_0042.jpg"]) == "second")
        #expect(AirDropBanner.pick(from: candidates, hints: ["Nobody"]) == "first")
        #expect(AirDropBanner.pick(from: [(element: String, context: String)](), hints: ["x"]) == nil)
    }
}

// MARK: Database

private nonisolated final class TestDatabase {
    let url: URL
    private var db: OpaquePointer?

    init(schema: String = TestDatabase.realSchema) throws {
        url = FileManager.default.temporaryDirectory.appending(path: "notif-test-\(UUID().uuidString).db")
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        try exec(schema)
    }

    deinit {
        sqlite3_close(db)
        try? FileManager.default.removeItem(at: url)
    }

    /// The columns of usernoted's tables this reader uses (others omitted).
    static let realSchema = """
    CREATE TABLE app (app_id INTEGER PRIMARY KEY, identifier VARCHAR);
    CREATE TABLE record (rec_id INTEGER PRIMARY KEY, app_id INTEGER, uuid BLOB, data BLOB, delivered_date REAL);
    INSERT INTO app VALUES (1, 'com.apple.MobileSMS'), (2, 'com.apple.sharingd');
    """

    func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            throw NSError(domain: "sqlite", code: 1, userInfo: [NSLocalizedDescriptionKey: error.map { String(cString: $0) } ?? "?"])
        }
    }

    func insert(appID: Int64, data: Data) throws {
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO record (app_id, data) VALUES (?, ?)", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, appID)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        #expect(sqlite3_step(statement) == SQLITE_DONE)
    }

    func delete(rowID: Int64) throws { try exec("DELETE FROM record WHERE rec_id = \(rowID)") }
}

struct NotificationDatabaseTests {
    @Test func readsRowsAfterACursorWithTheirApp() throws {
        let database = try TestDatabase()
        try database.insert(appID: 1, data: try blob("notif-synthetic-messages-direct"))
        try database.insert(appID: 2, data: try blob("notif-synthetic-airdrop"))

        let reader = try NotificationDatabase(url: database.url)
        #expect(try reader.maxRowID() == 2)
        let rows = try reader.rows(after: 0)
        #expect(rows.map(\.rowID) == [1, 2])
        #expect(rows.map(\.appIdentifier) == ["com.apple.MobileSMS", "com.apple.sharingd"])
        #expect(try reader.rows(after: 1).map(\.rowID) == [2])
        #expect(try reader.present([1, 2, 99]) == [1, 2])
        try database.delete(rowID: 1)
        #expect(try reader.present([1, 2]) == [2])
    }

    @Test func foreignSchemaIsAMismatchNotAnError() throws {
        let database = try TestDatabase(schema: "CREATE TABLE record (id INTEGER, payload BLOB); CREATE TABLE app (app_id INTEGER, identifier TEXT);")
        #expect(throws: NotificationDatabaseError.self) { try NotificationDatabase(url: database.url) }
        do {
            _ = try NotificationDatabase(url: database.url)
        } catch let error as NotificationDatabaseError {
            guard case .schemaMismatch = error else { Issue.record("expected schemaMismatch, got \(error)"); return }
        }
    }

    @Test func missingFileIsUnavailable() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "notif-missing-\(UUID().uuidString)/db")
        do {
            _ = try NotificationDatabase(url: missing)
            Issue.record("opened a file that does not exist")
        } catch let error as NotificationDatabaseError {
            guard case .unavailable = error else { Issue.record("expected unavailable, got \(error)"); return }
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}

struct NotificationFeedTests {
    @Test func startsAtTheNewestRowThenReportsOnlyNewOnes() throws {
        let database = try TestDatabase()
        try database.insert(appID: 1, data: try blob("notif-synthetic-messages-direct")) // delivered before the feed started
        let feed = NotificationFeed(url: database.url)

        #expect(feed.pollOnce() == nil) // opens, takes the cursor
        #expect(feed.pollOnce()?.isEmpty == true)

        try database.insert(appID: 1, data: try blob("notif-synthetic-messages-group"))
        let update = try #require(feed.pollOnce())
        #expect(update.records.map(\.rowID) == [2])
        #expect(update.records.first?.bundleID == "com.apple.MobileSMS")
        #expect(feed.pollOnce()?.isEmpty == true) // not replayed
    }

    @Test func trackedRowsReportWhenTheyLeaveTheTable() throws {
        let database = try TestDatabase()
        let feed = NotificationFeed(url: database.url)
        _ = feed.pollOnce()
        try database.insert(appID: 2, data: try blob("notif-synthetic-airdrop"))
        let update = try #require(feed.pollOnce())
        #expect(update.records.count == 1)

        feed.track(update.records[0].rowID)
        // `track` hops onto the feed's queue; poll only after it has run.
        Thread.sleep(forTimeInterval: 0.2)
        #expect(feed.pollOnce()?.removed == [])
        try database.delete(rowID: update.records[0].rowID)
        #expect(feed.pollOnce()?.removed == [update.records[0].rowID])
        #expect(feed.pollOnce()?.removed == []) // reported once
    }

    @Test func rowWithoutAppColumnUsesTheJoinedIdentifier() throws {
        // The blob has no `app` key: the identifier from the `app` table names the sender.
        let database = try TestDatabase()
        let plist = try PropertyListSerialization.data(fromPropertyList: ["req": ["titl": "T", "body": "B"]], format: .binary, options: 0)
        let feed = NotificationFeed(url: database.url)
        _ = feed.pollOnce()
        try database.insert(appID: 1, data: plist)
        #expect(feed.pollOnce()?.records.first?.bundleID == "com.apple.MobileSMS")
    }

    @Test func schemaMismatchSwitchesTheFeedOff() throws {
        let database = try TestDatabase(schema: "CREATE TABLE record (x INTEGER); CREATE TABLE app (y INTEGER);")
        let feed = NotificationFeed(url: database.url)
        #expect(feed.pollOnce() == nil)
        #expect(feed.pollOnce() == nil) // stays off; no retry
    }

    @Test func unreadableDatabaseIsRetriedWithBackoff() throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "notif-late-\(UUID().uuidString).db")
        let feed = NotificationFeed(url: missing, retryEvery: 2)
        #expect(feed.pollOnce() == nil) // tries, fails
        #expect(feed.pollOnce() == nil) // waits
        #expect(feed.pollOnce() == nil) // waits
        // The file shows up (Full Disk Access granted): the next try opens it at its newest row.
        let created = try TestDatabase()
        try FileManager.default.copyItem(at: created.url, to: missing)
        defer { try? FileManager.default.removeItem(at: missing) }
        #expect(feed.pollOnce() == nil) // opens
        #expect(feed.pollOnce()?.isEmpty == true) // and now polls
    }
}
