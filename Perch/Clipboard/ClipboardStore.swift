import AppKit
import CryptoKit
import Foundation
import GRDB

/// SQLite-backed clipboard history. Files are referenced by path and never copied; images live as PNGs in `imageDirectory`.
@Observable
final class ClipboardStore {
    nonisolated static let maxUnpinned = 200
    nonisolated static let maxAge: TimeInterval = 7 * 24 * 3600

    static let shared: ClipboardStore = {
        let base = URL.applicationSupportDirectory.appending(path: "Perch", directoryHint: .isDirectory)
        if let store = try? ClipboardStore(directory: base) { return store }
        let fallback = FileManager.default.temporaryDirectory
            .appending(path: "PerchClipboard-\(UUID().uuidString)", directoryHint: .isDirectory)
        do { return try ClipboardStore(directory: fallback) }
        catch { fatalError("Clipboard store unavailable: \(error)") }
    }()

    let imageDirectory: URL
    /// Bumps on every mutation; UI observes it to refetch.
    private(set) var revision = 0

    @ObservationIgnored private let dbQueue: DatabaseQueue
    @ObservationIgnored private let now: () -> Date

    init(directory: URL, now: @escaping () -> Date = Date.init) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let images = directory.appending(path: "ClipImages", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: images, withIntermediateDirectories: true)
        let databaseURL = directory.appending(path: "clipboard.sqlite")
        dbQueue = try Self.openRecovering(at: databaseURL)
        self.imageDirectory = images
        self.now = now
        enforceRetention()
    }

    /// An unopenable or unmigratable database is deleted and recreated.
    nonisolated private static func openRecovering(at url: URL) throws -> DatabaseQueue {
        do {
            return try openDatabase(at: url)
        } catch {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
            return try openDatabase(at: url)
        }
    }

    nonisolated private static func openDatabase(at url: URL) throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: url.path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "clip") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("text", .text)
                t.column("imagePath", .text)
                t.column("sourceBundleID", .text)
                t.column("hash", .text).notNull().unique()
                t.column("pinnedAt", .double)
                t.column("createdAt", .double).notNull()
            }
            try db.create(index: "clip_on_createdAt", on: "clip", columns: ["createdAt"])
        }
        try migrator.migrate(queue)
        return queue
    }

    // MARK: Insert

    func insertText(_ text: String, source: String?) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        insert(kind: .text, text: text, imageData: nil, source: source)
    }

    func insertFiles(_ urls: [URL], source: String?) {
        let paths = urls.filter(\.isFileURL).map(\.path)
        guard !paths.isEmpty else { return }
        insert(kind: .file, text: paths.joined(separator: "\n"), imageData: nil, source: source)
    }

    func insertImage(pngData: Data, source: String?) {
        guard !pngData.isEmpty else { return }
        insert(kind: .image, text: nil, imageData: pngData, source: source)
    }

    private func insert(kind: ClipboardItem.Kind, text: String?, imageData: Data?, source: String?) {
        let hash = Self.hash(kind: kind, text: text, data: imageData)
        let date = now()
        let stamp = date.timeIntervalSince1970
        let imageDirectory = self.imageDirectory
        let kindName = kind.rawValue
        do {
            try dbQueue.write { db in
                if let id = try Int64.fetchOne(db, sql: "SELECT id FROM clip WHERE hash = ?", arguments: [hash]) {
                    try db.execute(sql: "UPDATE clip SET createdAt = ? WHERE id = ?", arguments: [stamp, id])
                } else {
                    var imagePath: String?
                    if let imageData {
                        let fileURL = imageDirectory.appending(path: "\(hash).png")
                        try imageData.write(to: fileURL, options: .atomic)
                        imagePath = fileURL.path
                    }
                    try db.execute(
                        sql: """
                        INSERT INTO clip (kind, text, imagePath, sourceBundleID, hash, pinnedAt, createdAt)
                        VALUES (?, ?, ?, ?, ?, NULL, ?)
                        """,
                        arguments: [kindName, text, imagePath, source, hash, stamp]
                    )
                }
                try Self.applyRetention(db, now: date, imageDirectory: imageDirectory)
            }
            revision += 1
        } catch {
            NSLog("Perch: clipboard insert failed: \(error)")
        }
    }

    nonisolated private static func hash(kind: ClipboardItem.Kind, text: String?, data: Data?) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(kind.rawValue.utf8))
        hasher.update(data: Data([0]))
        if let text { hasher.update(data: Data(text.utf8)) }
        if let data { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Query

    func search(_ query: String, filter: ClipFilter = .all, limit: Int = 50) -> [ClipboardItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let (pinned, unpinned) = try dbQueue.read { db -> ([ClipboardItem], [ClipboardItem]) in
                var clause = ""
                var arguments: StatementArguments = []
                if !needle.isEmpty {
                    clause = "AND text LIKE ? ESCAPE '\\'"
                    arguments = ["%" + Self.escapeLike(needle) + "%"]
                }
                let pinnedRows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM clip WHERE pinnedAt IS NOT NULL \(clause) ORDER BY pinnedAt ASC, id ASC",
                    arguments: arguments
                )
                let unpinnedRows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM clip WHERE pinnedAt IS NULL \(clause) ORDER BY createdAt DESC, id DESC",
                    arguments: arguments
                )
                return (pinnedRows.map(Self.item(from:)), unpinnedRows.map(Self.item(from:)))
            }
            let keep: (ClipboardItem) -> Bool = { item in
                guard filter.matches(item) else { return false }
                // LIKE saw the whole path; for file rows only the file names should match.
                guard !needle.isEmpty, item.kind == .file else { return true }
                return item.fileURLs.contains { $0.lastPathComponent.localizedCaseInsensitiveContains(needle) }
            }
            return Array((pinned.filter(keep) + unpinned.filter(keep)).prefix(max(0, limit)))
        } catch {
            NSLog("Perch: clipboard search failed: \(error)")
            return []
        }
    }

    nonisolated private static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    nonisolated private static func item(from row: Row) -> ClipboardItem {
        let pinned: Double? = row["pinnedAt"]
        let created: Double = row["createdAt"]
        return ClipboardItem(
            id: row["id"],
            kind: ClipboardItem.Kind(rawValue: row["kind"]) ?? .text,
            text: row["text"],
            imagePath: row["imagePath"],
            sourceBundleID: row["sourceBundleID"],
            hash: row["hash"],
            pinnedAt: pinned.map(Date.init(timeIntervalSince1970:)),
            createdAt: Date(timeIntervalSince1970: created)
        )
    }

    // MARK: Mutations

    func pin(_ id: Int64) {
        let stamp = now().timeIntervalSince1970
        mutate { db in
            try db.execute(sql: "UPDATE clip SET pinnedAt = ? WHERE id = ? AND pinnedAt IS NULL", arguments: [stamp, id])
        }
    }

    /// The row becomes the newest entry.
    func unpin(_ id: Int64) {
        let stamp = now().timeIntervalSince1970
        mutate { db in
            try db.execute(
                sql: "UPDATE clip SET pinnedAt = NULL, createdAt = ? WHERE id = ? AND pinnedAt IS NOT NULL",
                arguments: [stamp, id]
            )
        }
    }

    /// `createdAt = now` in place. No-op for pinned rows.
    func promote(_ id: Int64) {
        let stamp = now().timeIntervalSince1970
        mutate { db in
            try db.execute(sql: "UPDATE clip SET createdAt = ? WHERE id = ? AND pinnedAt IS NULL", arguments: [stamp, id])
        }
    }

    func delete(_ id: Int64) {
        let imageDirectory = self.imageDirectory
        mutate { db in
            try db.execute(sql: "DELETE FROM clip WHERE id = ?", arguments: [id])
            try Self.removeOrphanImages(db, imageDirectory: imageDirectory)
        }
    }

    /// Deletes unpinned rows and their image files. Independent of `AppSettings.clipboardEnabled`.
    func clearHistory() {
        let imageDirectory = self.imageDirectory
        mutate { db in
            try db.execute(sql: "DELETE FROM clip WHERE pinnedAt IS NULL")
            try Self.removeOrphanImages(db, imageDirectory: imageDirectory)
        }
    }

    private func enforceRetention() {
        let date = now()
        let imageDirectory = self.imageDirectory
        mutate { db in try Self.applyRetention(db, now: date, imageDirectory: imageDirectory) }
    }

    private func mutate(_ body: @escaping @Sendable (Database) throws -> Void) {
        do {
            try dbQueue.write(body)
            revision += 1
        } catch {
            NSLog("Perch: clipboard write failed: \(error)")
        }
    }

    // MARK: Retention

    /// Deletes unpinned rows beyond `maxUnpinned` or older than `maxAge`, then orphan image files.
    nonisolated private static func applyRetention(_ db: Database, now: Date, imageDirectory: URL) throws {
        let cutoff = now.timeIntervalSince1970 - maxAge
        try db.execute(
            sql: """
            DELETE FROM clip WHERE pinnedAt IS NULL AND (
                createdAt < ?
                OR id IN (
                    SELECT id FROM clip WHERE pinnedAt IS NULL
                    ORDER BY createdAt DESC, id DESC LIMIT -1 OFFSET ?
                )
            )
            """,
            arguments: [cutoff, maxUnpinned]
        )
        try removeOrphanImages(db, imageDirectory: imageDirectory)
    }

    /// Removes regular files directly inside `imageDirectory` that no row references. Never touches anything outside it.
    nonisolated private static func removeOrphanImages(_ db: Database, imageDirectory: URL) throws {
        let referenced = Set(
            try String.fetchAll(db, sql: "SELECT imagePath FROM clip WHERE imagePath IS NOT NULL")
                .map { URL(fileURLWithPath: $0).lastPathComponent }
        )
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: imageDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries where !referenced.contains(entry.lastPathComponent) {
            guard (try? entry.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }
}
