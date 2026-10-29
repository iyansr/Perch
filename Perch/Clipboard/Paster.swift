import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// What a chord does with a clipboard row.
enum ClipAction: Equatable {
    /// ↵: write, close the panel, ⌘V into the previous app.
    case paste
    /// ⌘↵: write only.
    case copy
    /// ⌃⌘↵: like `.paste`, but as plain text (a file row pastes its path).
    case plainPaste
    /// ⌥↵: ⌘V straight to the previous app, panel stays open, no promotion.
    case keepOpen
}

/// Writes clipboard rows back to the pasteboard and posts the synthetic ⌘V.
final class Paster {
    static let shared = Paster()

    /// Pastes closer together than this are dropped (key repeat, double tap).
    static let dropWindow: TimeInterval = 0.25
    /// Longest wait for the target app to become active before ⌘V goes out anyway.
    static let activationTimeout: TimeInterval = 0.3

    enum WriteResult: Equatable {
        case written
        /// A file or image behind the row is gone. Nothing was written; the message is for the HUD.
        case missing(String)
    }

    private var lastPasteAt: Date?
    private var pending: Pending?

    /// Whether ⌘V can be synthesised; without Accessibility only copying works.
    var canPaste: Bool { AXIsProcessTrusted() }

    /// True when this paste follows the previous one too closely and must be dropped.
    func isDoublePaste(now: Date = Date()) -> Bool {
        guard let lastPasteAt else { return false }
        return now.timeIntervalSince(lastPasteAt) < Self.dropWindow
    }

    // MARK: Step 1: pasteboard

    /// Replaces the pasteboard with the row's content, stamped with `.perchInternal` so the monitor skips it.
    /// - Parameter plain: text form only; a file row writes its path(s) as a string.
    func write(_ item: ClipboardItem, plain: Bool) -> WriteResult {
        let pasteboardItem = NSPasteboardItem()
        switch item.kind {
        case .text:
            pasteboardItem.setString(item.text ?? "", forType: .string)
        case .file:
            let urls = item.fileURLs
            let manager = FileManager.default
            let missing = urls.filter { !manager.fileExists(atPath: $0.path) }
            if urls.isEmpty || !missing.isEmpty {
                return .missing(urls.count == 1 ? "File no longer exists" : "Some files no longer exist")
            }
            if plain {
                pasteboardItem.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            } else {
                // Finder-style: the first URL rides on this item; the rest follow as items of their own.
                let extra = urls.dropFirst().map { url -> NSPasteboardItem in
                    let other = NSPasteboardItem()
                    other.setString(url.absoluteString, forType: .fileURL)
                    return other
                }
                pasteboardItem.setString(urls[0].absoluteString, forType: .fileURL)
                pasteboardItem.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
                return commit(pasteboardItem, extra: Array(extra))
            }
        case .image:
            guard let path = item.imagePath, let data = FileManager.default.contents(atPath: path) else {
                return .missing("Image no longer exists")
            }
            pasteboardItem.setData(data, forType: .png)
        }
        return commit(pasteboardItem, extra: [])
    }

    private func commit(_ item: NSPasteboardItem, extra: [NSPasteboardItem]) -> WriteResult {
        item.setData(Data("1".utf8), forType: .perchInternal)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item] + extra)
        return .written
    }

    // MARK: Steps 3–4: ⌘V

    /// Posts ⌘V and then runs `completion` (promotion).
    ///
    /// - Parameters:
    ///   - target: app that should receive the paste; it is expected to be coming forward already.
    ///   - direct: post to `target`'s pid and do not wait for activation (⌥↵, panel stays open).
    ///   - prepare: runs right before the keystroke; releases the panel's key status.
    func postPaste(
        to target: NSRunningApplication?,
        direct: Bool,
        prepare: @escaping () -> Void,
        completion: @escaping () -> Void
    ) {
        lastPasteAt = Date()
        pending?.cancel()
        pending = nil

        if direct, let target {
            Self.postCommandV(toPID: target.processIdentifier)
            completion()
            return
        }
        // Already frontmost (or unknown): no activation event will come, only the key hand-over remains.
        guard let target, !target.isActive else {
            fire(prepare: prepare, completion: completion)
            return
        }

        let pending = Pending(pid: target.processIdentifier) { [weak self] in
            self?.pending = nil
            self?.fire(prepare: prepare, completion: completion)
        }
        self.pending = pending
        pending.start(timeout: Self.activationTimeout)
    }

    private func fire(prepare: () -> Void, completion: @escaping () -> Void) {
        prepare()
        // One tick for the target's window to become key after the panel lets go.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            Self.postCommandV(toPID: nil)
            completion()
        }
    }

    /// ⌘V as key down + key up. `pid == nil` goes through the HID tap to whoever has focus.
    private static func postCommandV(toPID pid: pid_t?) {
        let source = CGEventSource(stateID: .hidSystemState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: keyDown) else {
                continue
            }
            // Explicit flags: held ⌃/⌥ from the chord must not leak into the paste.
            event.flags = .maskCommand
            if let pid {
                event.postToPid(pid)
            } else {
                event.post(tap: .cghidEventTap)
            }
        }
    }

    /// Waits for `didActivateApplicationNotification` of one pid, or the timeout.
    private final class Pending {
        private let pid: pid_t
        private var action: (() -> Void)?
        private var observer: NSObjectProtocol?

        init(pid: pid_t, action: @escaping () -> Void) {
            self.pid = pid
            self.action = action
        }

        func start(timeout: TimeInterval) {
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.processIdentifier == self?.pid else { return }
                MainActor.assumeIsolated { self?.finish() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish()
            }
        }

        func cancel() {
            action = nil
            stopObserving()
        }

        private func finish() {
            let run = action
            action = nil
            stopObserving()
            run?()
        }

        private func stopObserving() {
            if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
            observer = nil
        }
    }
}
