import AppKit
import SwiftUI

/// The recorder currently listening; starting another one stops it.
@Observable
private final class ShortcutRecording {
    static let shared = ShortcutRecording()
    var active: HotkeySlot?
}

/// Click to record: captures the next keyDown (Esc cancels) and requires at least one modifier.
/// Rejects a shortcut another Perch shortcut or another app already uses. `slot` is where the shortcut is
/// registered, so re-recording the same shortcut is not a conflict with itself.
struct ShortcutRecorderView: View {
    let slot: HotkeySlot
    @Binding var shortcut: Shortcut?
    /// Shows × to remove the shortcut; the open/close shortcut must always have one.
    var clearable = true
    var placeholder = "Record Shortcut"

    @State private var message: String?
    @State private var monitor: Any?
    private var recording = ShortcutRecording.shared

    private var isRecording: Bool { recording.active == slot }

    var body: some View {
        HStack(spacing: 6) {
            if let message {
                Text(message).font(.caption).foregroundStyle(.red)
            }
            Button {
                isRecording ? stop() : start()
            } label: {
                if isRecording {
                    Text("Press shortcut…")
                } else if let shortcut {
                    ShortcutKeys(shortcut: shortcut)
                } else {
                    Text(placeholder)
                }
            }
            .controlSize(.small)
            if clearable, shortcut != nil, !isRecording {
                Button {
                    shortcut = nil
                    message = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove shortcut")
            }
        }
        .onChange(of: recording.active) { _, active in
            if active != slot { removeMonitor() }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        message = nil
        if recording.active == nil { HotkeyManager.shared.suspend() }
        recording.active = slot
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        removeMonitor()
        guard recording.active == slot else { return }
        recording.active = nil
        HotkeyManager.shared.resume()
    }

    private func removeMonitor() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 { stop(); return } // Esc
        guard let candidate = Shortcut(event: event) else {
            message = "Include ⌃, ⌥, ⇧ or ⌘"
            return
        }
        if let owner = HotkeyManager.shared.owner(of: candidate), owner != slot {
            message = "Used by \(Self.name(of: owner))"
        } else if !HotkeyManager.shared.isAvailable(candidate) {
            message = "Taken by another app"
        } else {
            shortcut = candidate
            message = nil
            stop()
        }
    }

    private static func name(of slot: HotkeySlot) -> String {
        switch slot {
        case .open: return "Open Perch"
        case .dictation: return "Dictation"
        case let .launcher(key):
            switch LauncherItem(key: key) {
            case let .app(url)?: return url.deletingPathExtension().lastPathComponent
            case let .setting(pane)?: return pane.title
            case let .command(command)?: return command.title
            case nil: return "another shortcut"
            }
        }
    }
}

extension ShortcutRecorderView {
    /// For a shortcut that always exists, such as Open Perch.
    init(slot: HotkeySlot, shortcut: Binding<Shortcut>) {
        self.init(slot: slot, shortcut: Binding(get: { shortcut.wrappedValue }, set: { if let new = $0 { shortcut.wrappedValue = new } }),
                  clearable: false)
    }
}

/// A shortcut as separate key caps: ⇧ ⌘ C.
struct ShortcutKeys: View {
    let shortcut: Shortcut

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(shortcut.keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 11, weight: .medium))
                    .frame(minWidth: 12)
            }
        }
    }
}
