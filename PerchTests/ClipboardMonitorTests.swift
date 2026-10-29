import AppKit
import Testing
import Foundation
@testable import Perch

struct ClipboardMonitorTests {
    private let home = FileManager.default.homeDirectoryForCurrentUser

    private func scratchPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("perch.tests.\(UUID().uuidString)"))
    }

    // MARK: Volatile roots

    @Test func volatileRootsAreRejectedThroughSymlinksAndPrivatePrefixes() {
        #expect(ClipboardMonitor.isVolatile(URL(fileURLWithPath: "/private/tmp/x")))
        #expect(ClipboardMonitor.isVolatile(URL(fileURLWithPath: "/tmp/x")))   // symlink to /private/tmp
        #expect(ClipboardMonitor.isVolatile(URL(fileURLWithPath: "/private/var/folders/x")))
        #expect(ClipboardMonitor.isVolatile(URL(fileURLWithPath: "/var/folders/zz/T/x.png")))
        #expect(ClipboardMonitor.isVolatile(home.appending(path: "Library/Caches/com.apple.x/file")))
    }

    @Test func nonVolatilePathsAreAccepted() {
        #expect(!ClipboardMonitor.isVolatile(home.appending(path: "Documents/x")))
        #expect(!ClipboardMonitor.isVolatile(URL(fileURLWithPath: "/tmpfoo/x")))
        #expect(!ClipboardMonitor.isVolatile(URL(fileURLWithPath: "/Applications/Safari.app")))
        #expect(!ClipboardMonitor.isVolatile(home.appending(path: "Library/Caches-old/x")))
    }

    // MARK: File cap

    @Test func fileBatchIsCappedAt32() {
        let urls = (0..<40).map { home.appending(path: "Documents/f\($0).txt") }
        let kept = ClipboardMonitor.capturableFiles(urls)
        #expect(kept.count == 32)
        #expect(kept.first == urls.first)
        #expect(kept.last == urls[31])
    }

    @Test func volatileFilesAreDroppedBeforeTheCap() {
        let volatile = (0..<10).map { URL(fileURLWithPath: "/tmp/v\($0)") }
        let real = (0..<32).map { home.appending(path: "Documents/r\($0).txt") }
        #expect(ClipboardMonitor.capturableFiles(volatile + real) == real)
        #expect(ClipboardMonitor.capturableFiles(volatile).isEmpty)
    }

    // MARK: File vs text

    private func writeItem(_ pasteboard: NSPasteboard, string: String?, fileURL: URL?) {
        let item = NSPasteboardItem()
        if let string { item.setString(string, forType: .string) }
        if let fileURL { item.setString(fileURL.absoluteString, forType: .fileURL) }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    @Test func fileURLWinsOverDisplayNameString() throws {
        let pasteboard = scratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        let file = home.appending(path: "Documents/IMG_1234.png")
        writeItem(pasteboard, string: "IMG_1234.png", fileURL: file)

        guard case .files(let urls)? = ClipboardMonitor.payload(from: pasteboard) else {
            Issue.record("expected a files payload")
            return
        }
        #expect(urls.map(\.path) == [file.path])
    }

    @Test func fallsThroughToTextWhenEveryFileIsVolatile() {
        let pasteboard = scratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        writeItem(pasteboard, string: "screenshot.png", fileURL: URL(fileURLWithPath: "/private/tmp/screenshot.png"))

        guard case .text(let text)? = ClipboardMonitor.payload(from: pasteboard) else {
            Issue.record("expected a text payload")
            return
        }
        #expect(text == "screenshot.png")
    }

    @Test func httpURLOnFileURLTypeIsNotAFile() {
        let pasteboard = scratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString("https://example.com/a", forType: .string)
        item.setString("https://example.com/a", forType: .fileURL)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        guard case .text(let text)? = ClipboardMonitor.payload(from: pasteboard) else {
            Issue.record("expected a text payload")
            return
        }
        #expect(text == "https://example.com/a")
    }

    @Test func multipleItemsEachContributeTheirOwnFileURL() {
        let pasteboard = scratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        let files = (0..<3).map { home.appending(path: "Documents/m\($0).txt") }
        pasteboard.clearContents()
        pasteboard.writeObjects(files.map { $0 as NSURL })

        guard case .files(let urls)? = ClipboardMonitor.payload(from: pasteboard) else {
            Issue.record("expected a files payload")
            return
        }
        #expect(urls.map(\.path) == files.map(\.path))
    }

    @Test func textIsCappedAt32000Characters() {
        let pasteboard = scratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        writeItem(pasteboard, string: String(repeating: "a", count: 40_000), fileURL: nil)

        guard case .text(let text)? = ClipboardMonitor.payload(from: pasteboard) else {
            Issue.record("expected a text payload")
            return
        }
        #expect(text.count == 32_000)
    }

    @Test func blankTextIsIgnored() {
        let pasteboard = scratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        writeItem(pasteboard, string: "  \n ", fileURL: nil)
        #expect(ClipboardMonitor.payload(from: pasteboard) == nil)
    }

    // MARK: Guards

    @Test func concealedTransientAutogeneratedAndPasswordManagerItemsAreSkipped() {
        for type in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                     "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword"] {
            let pasteboard = scratchPasteboard()
            defer { pasteboard.releaseGlobally() }
            let item = NSPasteboardItem()
            item.setString("secret", forType: .string)
            item.setString("1", forType: NSPasteboard.PasteboardType(type))
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
            #expect(!ClipboardMonitor.shouldCapture(pasteboard), "\(type)")
        }
    }

    @Test func perchOwnWritesAreSkipped() {
        let pasteboard = scratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString("pasted by perch", forType: .string)
        item.setString("1", forType: .perchInternal)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        #expect(!ClipboardMonitor.shouldCapture(pasteboard))
    }

    @Test func ordinaryCopyIsCaptured() {
        let pasteboard = scratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        writeItem(pasteboard, string: "hello", fileURL: nil)
        #expect(ClipboardMonitor.shouldCapture(pasteboard))
    }

    // MARK: Images

    @Test func tiffIsReencodedToPNGAndPNGPassesThrough() throws {
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(ClipboardMonitor.pngData(from: tiff, isPNG: false))
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(ClipboardMonitor.pngData(from: png, isPNG: true) == png)
    }

    // MARK: End to end through the store

    @Test func pollCapturesOnlyAfterChangeCountMoves() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "perch-monitor-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ClipboardStore(directory: dir)
        let pasteboard = scratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        let defaultsName = "perch.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let monitor = ClipboardMonitor(pasteboard: pasteboard, settings: AppSettings(defaults: defaults), store: store)

        monitor.poll()
        #expect(store.search("").isEmpty)

        writeItem(pasteboard, string: "first", fileURL: nil)
        monitor.poll()
        monitor.poll()
        #expect(store.search("").map(\.text) == ["first"])
    }
}
