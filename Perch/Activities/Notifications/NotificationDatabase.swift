import Foundation
import SQLite3
import os

nonisolated enum NotificationDatabaseError: Error, Equatable {
    /// No candidate file could be opened: missing, or Full Disk Access is off. Worth retrying.
    case unavailable(String)
    /// A database opened but its tables are not the ones this reader knows. Retrying cannot help.
    case schemaMismatch(String)
}

/// A row of usernoted's `record` table before its blob is decoded.
nonisolated struct RawNotificationRow: Equatable {
    let rowID: Int64
    /// `app.identifier`, joined by `record.app_id`.
    let appIdentifier: String?
    let data: Data
}

/// Read-only view of usernoted's notification database.
///
/// Where it lives: the per-user Darwin cache directory
/// (`$(getconf DARWIN_USER_DIR)/com.apple.notificationcenter/db2/db`). Needs Full Disk Access.
/// Tables used: `record(rec_id, app_id, data)` and `app(app_id, identifier)`.
///
/// The file is opened `SQLITE_OPEN_READONLY`, not `immutable=1`: the database is in WAL mode and an
/// immutable open ignores the `-wal` file, so it would never see a notification delivered after
/// usernoted's last checkpoint. A read-only connection takes no write lock and cannot checkpoint.
nonisolated final class NotificationDatabase {
    let url: URL
    private var handle: OpaquePointer?

    /// The database path, or nil when the Darwin user directory cannot be read.
    static func defaultURL() -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_DIR, &buffer, buffer.count) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
        return URL(fileURLWithPath: path).appending(path: "com.apple.notificationcenter/db2/db")
    }

    init(url: URL) throws {
        self.url = url
        var db: OpaquePointer?
        let code = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil)
        guard code == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(code)"
            sqlite3_close(db)
            throw NotificationDatabaseError.unavailable("\(url.path): \(message)")
        }
        handle = db
        sqlite3_busy_timeout(db, 150)
        do {
            try validateSchema()
        } catch {
            sqlite3_close(db)
            handle = nil
            throw error
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    /// Highest `rec_id`, or 0 for an empty table.
    func maxRowID() throws -> Int64 {
        try query("SELECT COALESCE(MAX(rec_id), 0) FROM record", bind: []) { sqlite3_column_int64($0, 0) }.first ?? 0
    }

    /// Rows after `rowID`, oldest first, at most `limit`.
    func rows(after rowID: Int64, limit: Int = 200) throws -> [RawNotificationRow] {
        try query(
            """
            SELECT r.rec_id, a.identifier, r.data FROM record r LEFT JOIN app a ON a.app_id = r.app_id
            WHERE r.rec_id > ? ORDER BY r.rec_id LIMIT \(limit)
            """,
            bind: [rowID]
        ) { statement in
            let identifier = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            let count = Int(sqlite3_column_bytes(statement, 2))
            let data = sqlite3_column_blob(statement, 2).map { Data(bytes: $0, count: count) } ?? Data()
            return RawNotificationRow(rowID: sqlite3_column_int64(statement, 0), appIdentifier: identifier, data: data)
        }
    }

    /// Which of `rowIDs` are still in the table (a banner that was answered or dismissed is deleted).
    func present(_ rowIDs: [Int64]) throws -> Set<Int64> {
        guard !rowIDs.isEmpty else { return [] }
        let marks = rowIDs.map { _ in "?" }.joined(separator: ",")
        let found = try query("SELECT rec_id FROM record WHERE rec_id IN (\(marks))", bind: rowIDs) { sqlite3_column_int64($0, 0) }
        return Set(found)
    }

    private func validateSchema() throws {
        let record = try columns(of: "record")
        let app = try columns(of: "app")
        guard ["rec_id", "app_id", "data"].allSatisfy(record.contains) else {
            throw NotificationDatabaseError.schemaMismatch("record has columns \(record.sorted())")
        }
        guard ["app_id", "identifier"].allSatisfy(app.contains) else {
            throw NotificationDatabaseError.schemaMismatch("app has columns \(app.sorted())")
        }
    }

    private func columns(of table: String) throws -> Set<String> {
        do {
            return Set(try query("PRAGMA table_info(\(table))", bind: []) { sqlite3_column_text($0, 1).map { String(cString: $0) } ?? "" })
        } catch NotificationDatabaseError.unavailable(let reason) {
            // A file that is not SQLite (or is encrypted) is a format change, not a missing permission.
            throw NotificationDatabaseError.schemaMismatch(reason)
        }
    }

    private func query<T>(_ sql: String, bind: [Int64], row: (OpaquePointer) -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw NotificationDatabaseError.unavailable(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bind.enumerated() { sqlite3_bind_int64(statement, Int32(index + 1), value) }
        var rows: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: rows.append(row(statement))
            case SQLITE_DONE: return rows
            default: throw NotificationDatabaseError.unavailable(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }
}

/// Polls the notification database once for every source that wants its records, and only while
/// at least one of them runs. Starts at the newest row, so notifications delivered earlier never replay.
///
/// A missing or unreadable database (no Full Disk Access) is retried quietly and logged once.
/// A schema this reader does not recognise switches the feed off for the rest of the run, also logged once.
nonisolated final class NotificationFeed: @unchecked Sendable {
    static let shared = NotificationFeed()

    struct Update {
        var records: [NotificationRecord] = []
        /// Tracked rows that left the table since the last poll.
        var removed: [Int64] = []
        var isEmpty: Bool { records.isEmpty && removed.isEmpty }
    }

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Perch", category: "NotificationFeed")

    private let queue = DispatchQueue(label: "perch.notification-feed", qos: .utility)
    private let url: URL?
    private let interval: DispatchTimeInterval
    private let retryEvery: Int

    // All of the below belongs to `queue`.
    private var subscribers: [String: @MainActor (Update) -> Void] = [:]
    private var timer: DispatchSourceTimer?
    private var database: NotificationDatabase?
    private var cursor: Int64?
    private var tracked: Set<Int64> = []
    private var ticksUntilOpen = 0
    private var isDisabled = false
    private var hasLoggedUnavailable = false

    init(url: URL? = NotificationDatabase.defaultURL(), interval: DispatchTimeInterval = .seconds(2), retryEvery: Int = 15) {
        self.url = url
        self.interval = interval
        self.retryEvery = retryEvery
    }

    /// `handler` runs on the main actor for every poll that found something.
    func subscribe(_ owner: String, handler: @escaping @MainActor (Update) -> Void) {
        queue.async { [self] in
            subscribers[owner] = handler
            guard timer == nil, !isDisabled else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(300))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    func unsubscribe(_ owner: String) {
        queue.async { [self] in
            subscribers[owner] = nil
            guard subscribers.isEmpty else { return }
            timer?.cancel()
            timer = nil
            database = nil
            cursor = nil // the next run starts from the newest row again
            tracked = []
        }
    }

    /// Reports when `rowID` disappears from the database (via `Update.removed`).
    func track(_ rowID: Int64) {
        queue.async { [self] in tracked.insert(rowID) }
    }

    func untrack(_ rowID: Int64) {
        queue.async { [self] in tracked.remove(rowID) }
    }

    private func tick() {
        guard let update = pollOnce(), !update.isEmpty else { return }
        let handlers = Array(subscribers.values)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { handlers.forEach { $0(update) } }
        }
    }

    /// One poll. Internal so tests can drive it without the timer; call it from one thread only.
    func pollOnce() -> Update? {
        guard !isDisabled else { return nil }
        if database == nil {
            if ticksUntilOpen > 0 {
                ticksUntilOpen -= 1
                return nil
            }
            do {
                guard let url else { throw NotificationDatabaseError.unavailable("Darwin user directory unknown") }
                let opened = try NotificationDatabase(url: url)
                database = opened
                if cursor == nil { cursor = try opened.maxRowID() }
                ticksUntilOpen = 0
                return nil
            } catch NotificationDatabaseError.schemaMismatch(let reason) {
                Self.log.error("Notification database not understood, mirror disabled: \(reason, privacy: .public)")
                isDisabled = true
                timer?.cancel()
                timer = nil
                return nil
            } catch {
                if !hasLoggedUnavailable {
                    hasLoggedUnavailable = true
                    Self.log.notice("Notification database unavailable (Full Disk Access?): \(String(describing: error), privacy: .public)")
                }
                ticksUntilOpen = retryEvery
                return nil
            }
        }

        guard let database, let current = cursor else { return nil }
        do {
            var update = Update()
            for row in try database.rows(after: current) {
                self.cursor = row.rowID
                if let record = NotificationBlob.decode(row.data, rowID: row.rowID, fallbackBundleID: row.appIdentifier) {
                    update.records.append(record)
                }
            }
            if !tracked.isEmpty {
                let present = try database.present(Array(tracked))
                update.removed = tracked.subtracting(present).sorted()
                tracked.subtract(update.removed)
            }
            return update
        } catch {
            // A busy or replaced file: reopen on the next tick, keeping the cursor.
            self.database = nil
            ticksUntilOpen = 0
            return nil
        }
    }
}
