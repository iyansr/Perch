import AppKit
import SwiftUI

/// Click to record: captures the next keyDown (Esc cancels) and requires at least one modifier.
struct ShortcutRecorderView: View {
    @Binding var shortcut: Shortcut
    @State private var isRecording = false
    @State private var message: String?
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button(isRecording ? "Press shortcut…" : shortcut.displayString) {
                isRecording ? stop() : start()
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        message = nil
        isRecording = true
        HotkeyManager.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        isRecording = false
        HotkeyManager.shared.resume()
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 { stop(); return } // Esc
        guard let candidate = Shortcut(event: event) else {
            message = "Include ⌃, ⌥, ⇧ or ⌘"
            return
        }
        if HotkeyManager.shared.register(candidate) {
            shortcut = candidate
            message = nil
            stop()
        } else {
            message = "Taken by another app"
        }
    }
}
