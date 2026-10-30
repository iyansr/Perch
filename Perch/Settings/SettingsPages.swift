import AppKit
import SwiftUI

struct GeneralSettingsPage: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageHeader(section: .general)
            SettingsGroup(title: "Global Shortcut") {
                SettingsRow(
                    symbol: "command",
                    title: "Open Perch",
                    detail: "Summon search from any app. Clicking the notch opens Home."
                ) {
                    ShortcutRecorderView(shortcut: $settings.hotkey)
                }
            }
            SettingsGroup(title: "Feedback") {
                SettingsRow(
                    symbol: "speaker.wave.2.fill",
                    title: "Play sounds",
                    detail: "Chime when a timer, conversion or agent finishes."
                ) {
                    Toggle("Play sounds", isOn: $settings.playsSounds)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
        }
    }
}

struct ClipboardSettingsPage: View {
    @Bindable private var settings = AppSettings.shared
    @State private var confirmsClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageHeader(section: .clipboard)
            SettingsGroup(title: "History") {
                SettingsRow(
                    symbol: "clock.arrow.circlepath",
                    tint: .orange,
                    title: "Clipboard history",
                    detail: "Record text, links and images you copy. Turning it off keeps what is already saved."
                ) {
                    Toggle("Clipboard history", isOn: $settings.clipboardEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                SettingsDivider()
                SettingsRow(
                    symbol: "trash",
                    tint: .red,
                    title: "Clear history",
                    detail: "Delete every saved item except pinned ones."
                ) {
                    Button("Clear…") { confirmsClear = true }
                }
            }
        }
        .confirmationDialog("Clear clipboard history?", isPresented: $confirmsClear) {
            Button("Clear History", role: .destructive) { ClipboardStore.shared.clearHistory() }
        } message: {
            Text("Pinned items stay. This cannot be undone.")
        }
    }
}

struct AgentsSettingsPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageHeader(section: .agents)
            SettingsGroup(title: "Coding Agents") {
                AgentConnectionList()
                    .padding(14)
            }
            Label(
                "Connecting adds Perch's hooks to the agent's config; your other hooks stay as they are.",
                systemImage: "info.circle"
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.top, 10)
            .padding(.leading, 4)
        }
    }
}

struct PermissionsSettingsPage: View {
    @State private var isTrusted = AccessibilityPermission.isTrusted

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageHeader(section: .permissions)
            SettingsGroup(title: "Accessibility") {
                SettingsRow(
                    symbol: "accessibility",
                    tint: .blue,
                    title: "Accessibility",
                    detail: "Lets Perch paste a clipboard item into the app you were using. Without it, items are only copied."
                ) {
                    if isTrusted {
                        GrantedBadge()
                    } else {
                        Button("Grant Access…") { AccessibilityPermission.requestPrompt() }
                    }
                }
                SettingsDivider()
                SettingsRow(
                    symbol: "arrow.up.forward.square",
                    tint: .secondary,
                    title: "Manage in System Settings",
                    detail: "Opens Privacy & Security › Accessibility."
                ) {
                    Button("Open…") { AccessibilityPermission.openSystemSettings() }
                }
            }
        }
        // Granting happens in System Settings; re-check every second while this page shows.
        .task {
            while !Task.isCancelled {
                let trusted = AccessibilityPermission.isTrusted
                if trusted != isTrusted { isTrusted = trusted }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

private struct GrantedBadge: View {
    var body: some View {
        Label("Granted", systemImage: "checkmark.circle.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.green)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(.green.opacity(0.15)))
    }
}

struct AboutSettingsPage: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Perch")
                .font(.system(size: 26, weight: .bold))
            Text(version)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .overlay { Capsule().strokeBorder(Color.primary.opacity(0.2)) }
            Text("Your notch, turned into a command center.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }
}
