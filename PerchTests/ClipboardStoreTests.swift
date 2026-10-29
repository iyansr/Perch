import Testing
import Foundation
@testable import Perch

final class TestClock {
    var now = Date(timeIntervalSince1970: 1_700_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

struct ClipboardStoreTests {
    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "perch-clip-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func texts(_ items: [ClipboardItem]) -> [String] { items.compactMap(\.text) }

    // MARK: Retention

    @Test func keeps200AndDropsTheOldestOn201st() throws {
        let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock()
        let store = try ClipboardStore(directory: dir, now: { clock.now })

        for i in 1...200 { store.insertText("item \(i)", source: nil); clock.advance(1) }
        #expect(store.search("", limit: 1000).count == 200)
        #expect(texts(store.search("item 1", limit: 1000)).contains("item 1"))

        store.insertText("item 201", source: nil)
        let all = store.search("", limit: 1000)
        #expect(all.count == 200)
        #expect(all.first?.text == "item 201")
        #expect(!texts(all).contains("item 1"))
        #expect(texts(all).contains("item 2"))
    }

    @Test func dropsRowsOlderThanSevenDaysOnlyPastTheBoundary() throws {
        let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock()
        let store = try ClipboardStore(directory: dir, now: { clock.now })
        let week: TimeInterval = 7 * 24 * 3600

        store.insertText("old", source: nil)
        clock.advance(week)
        store.insertText("boundary", source: nil)
        #expect(texts(store.search("")) == ["boundary", "old"], "exactly 7 days old is kept")

        clock.advance(1)
        store.insertText("fresh", source: nil)
        #expect(texts(store.search("")) == ["fresh", "boundary"], "7 days + 1 s is dropped")
    }

    @Test func retentionRunsAtLaunch() throws {
        let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock()
        let first = try ClipboardStore(directory: dir, now: { clock.now })
        first.insertText("stale", source: nil)
        clock.advance(7 * 24 * 3600 + 1)

        let second = try ClipboardStore(directory: dir, now: { clock.now })
        #expect(second.search("").isEmpty)
    }

    @Test func retentionRemovesOrphanImageFilesButNothingOutsideTheDirectory() throws {
        let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock()
        let store = try ClipboardStore(directory: dir, now: { clock.now })
        let outside = dir.appending(path: "keep-me.txt")
        try Data("x".utf8).write(to: outside)
        let orphan = store.imageDirectory.appending(path: "orphan.png")
        try Data("o".utf8).write(to: orphan)

        store.insertImage(pngData: Data("img".utf8), source: nil)
        let image = try #require(store.search("").first)
        let path = try #require(image.imagePath)
        #expect(path.hasPrefix(store.imageDirectory.path))
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: outside.path))

        clock.advance(7 * 24 * 3600 + 1)
        store.insertText("trigger", source: nil)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    // MARK: Dedupe

    @Test func dedupeUpdatesCreatedAtInPlace() throws {
        let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock()
        let store = try ClipboardStore(directory: dir, now: { clock.now })

        store.insertText("a", source: nil)
        clock.advance(1)
        store.insertText("b", source: nil)
        let original = try #require(store.search("a").first)
        clock.advance(1)
        store.insertText("a", source: nil)

        let all = store.search("")
        #expect(texts(all) == ["a", "b"])
        let again = try #require(all.first)
        #expect(again.id == original.id)
        #expect(again.createdAt > original.createdAt)
    }

    @Test func sameTextAsFileListIsADistinctRow() throws {
        let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ClipboardStore(directory: dir)
        store.insertText("/Users/x/a.png", source: nil)
        store.insertFiles([URL(fileURLWithPath: "/Users/x/a.png")], source: nil)
        #expect(store.search("").count == 2)
    }

    // MARK: Pins

    @Test func pinnedRowsLeadOldestPinFirst() throws {
        let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock()
        let store = try ClipboardStore(directory: dir, now: { clock.now })
        for name in ["a", "b", "c", "d"] { store.insertText(name, source: nil); clock.advance(1) }
        let id = { (t: String) in store.search(t).first!.id }

        store.pin(id("c")); clock.advance(1)
        store.pin(id("a"))

        let all = store.search("")
        #expect(texts(all) == ["c", "a", "d", "b"])
        #expect(all.map(\.isPinned) == [true, true, false, false])
    }

    @Test func pinnedRowsSurviveRetention() throws {
        let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock()
        let store = try ClipboardStore(directory: dir, now: { clock.now })
        store.insertText("pinned", source: nil)
        store.pin(try #require(store.search("pinned").first).id)

        for i in 1...205 { clock.advance(1); store.insertText("n\(i)", source: nil) }
        clock.advance(8 * 24 * 3600)
        store.insertText("late", source: nil)

        let all = store.search("", limit: 1000)
        #expect(all.first?.text == "pinned")
        #expect(all.count == 2)
    }

    @Test func unpinMakesTheRowNewest() throws {
        let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock()
        let store = try ClipboardStore(directory: dir, now: { clock.now })
        store.insertText("old", source: nil)
        let id = try #require(store.search("old").first).id
        store.pin(id)
        clock.advance(10)
        store.insertText("new", source: nil)
        #expect(texts(store.search("")) == ["old", "new"])

        clock.advance(10)
        store.unpin(id)
        let all = store.search("")
        #expect(texts(all) == ["old", "new"])
        #expect(all.allSatisfy { !$0.isPinned })
        #expect(all[0].createdAt > all[1].createdAt)
    }

    @Test func promoteMovesUnpinnedAndIgnoresPinned() throws {
        let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock()
        let store = try ClipboardStore(directory: dir, now: { clock.now })
        store.insertText("a", source: nil); clock.advance(1)
        store.insertText("b", source: nil); clock.advance(1)
        store.insertText("p", source: nil)
        let pinnedItem = try #require(store.search("p").first)
        store.pin(pinnedItem.id)
        clock.advance(1)

        store.promote(try #require(store.search("a").first).id)
        #expect(texts(store.search("")) == ["p", "a", "b"])

        let before = try #require(store.search("p").first)
        clock.advance(5)
        store.promote(pinnedItem.id)
        let after = try #require(store.search("p").first)
        #expect(after.createdAt == before.createdAt)
        #expect(after.pinnedAt == before.pinnedAt)
    }

    // MARK: Delete / clear

    @Test func clearHistoryKeepsPinsAndRemovesImageFiles() throws {
        let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock()
        let store = try ClipboardStore(directory: dir, now: { clock.now })
        store.insertText("keep", source: nil); clock.advance(1)
        store.insertText("drop", source: nil); clock.advance(1)
        store.insertImage(pngData: Data("one".utf8), source: nil)
        store.insertImage(pngData: Data("two".utf8), source: nil)
        store.pin(try #require(store.search("keep").first).id)

        let imagePaths = store.search("", filter: .images).compactMap(\.imagePath)
        #expect(imagePaths.count == 2)
        let revision = store.revision
        store.clearHistory()

        #expect(texts(store.search("")) == ["keep"])
        #expect(store.revision > revision)
        for path in imagePaths { #expect(!FileManager.default.fileExists(atPath: path)) }
    }

    @Test func deleteRemovesRowAndItsImage() throws {
        let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ClipboardStore(directory: dir)
        store.insertImage(pngData: Data("img".utf8), source: nil)
        let item = try #require(store.search("").first)
        let path = try #require(item.imagePath)

        store.delete(item.id)
        #expect(store.search("").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func deletingFileRowNeverTouchesTheFile() throws {
        let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "user-file.txt")
        try Data("x".utf8).write(to: file)
        let store = try ClipboardStore(directory: dir)
        store.insertFiles([file], source: nil)
        let item = try #require(store.search("").first)
        #expect(item.kind == .file)
        #expect(item.imagePath == nil)

        store.delete(item.id)
        store.clearHistory()
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: Search

    @Test func searchEscapesLikeWildcards() throws {
        let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ClipboardStore(directory: dir)
        store.insertText("100% sure", source: nil)
        store.insertText("snake_case", source: nil)
        store.insertText("plain words", source: nil)

        #expect(texts(store.search("%")) == ["100% sure"])
        #expect(texts(store.search("_")) == ["snake_case"])
        #expect(texts(store.search("PLAIN")) == ["plain words"])
    }

    @Test func fileSearchMatchesFileNamesNotDirectories() throws {
        let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ClipboardStore(directory: dir)
        store.insertFiles([URL(fileURLWithPath: "/Users/someone/Documents/report.pdf")], source: nil)

        #expect(store.search("report").count == 1)
        #expect(store.search("someone").isEmpty)
    }

    @Test func filtersApplyAfterPinnedSplit() throws {
        let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock()
        let store = try ClipboardStore(directory: dir, now: { clock.now })
        let entries = ["plain note", "https://example.com/x", "me@example.com", "#FF8800", "https://swift.org"]
        for entry in entries { store.insertText(entry, source: nil); clock.advance(1) }
        store.insertFiles([URL(fileURLWithPath: "/Users/x/a.png")], source: nil); clock.advance(1)
        store.insertImage(pngData: Data("img".utf8), source: nil)
        store.pin(try #require(store.search("example.com/x").first).id)

        #expect(texts(store.search("", filter: .links)) == ["https://example.com/x", "https://swift.org"])
        #expect(store.search("", filter: .links).map(\.isPinned) == [true, false])
        #expect(texts(store.search("", filter: .emails)) == ["me@example.com"])
        #expect(texts(store.search("", filter: .colors)) == ["#FF8800"])
        #expect(store.search("", filter: .images).count == 1)
        #expect(store.search("", filter: .files).count == 1)
        #expect(store.search("", filter: .text).count == 5)
        #expect(store.search("", filter: .all).count == 7)
        #expect(store.search("", limit: 3).count == 3)
    }

    // MARK: Recovery

    @Test func unopenableDatabaseIsRecreated() throws {
        let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data("this is not a sqlite database, just junk bytes".utf8).write(to: dir.appending(path: "clipboard.sqlite"))

        let store = try ClipboardStore(directory: dir)
        store.insertText("works", source: nil)
        #expect(texts(store.search("")) == ["works"])
    }

    @Test func revisionBumpsOnMutation() throws {
        let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ClipboardStore(directory: dir)
        let start = store.revision
        store.insertText("x", source: nil)
        #expect(store.revision > start)
    }

    // MARK: Text forms

    @Test func textFormClassification() {
        func form(_ text: String) -> ClipboardItem.TextForm {
            ClipboardItem(id: 1, kind: .text, text: text, imagePath: nil, sourceBundleID: nil, hash: "h",
                          pinnedAt: nil, createdAt: .now).textForm
        }
        #expect(form("https://example.com/a?b=1") == .link(URL(string: "https://example.com/a?b=1")!))
        #expect(form("me@example.com") == .email("me@example.com"))
        #expect(form("#abc") == .color(hex: "#ABC"))
        #expect(form("#ff8800") == .color(hex: "#FF8800"))
        #expect(form("#ff880080") == .color(hex: "#FF880080"))
        #expect(form("#ff88") == .plain)
        #expect(form("#xyz123") == .plain)
        #expect(form("see https://example.com") == .plain)
        #expect(form("a@b") == .plain)
        #expect(form("hello") == .plain)
    }
}
