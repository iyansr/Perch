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
                    ShortcutRecorderView(slot: .open, shortcut: $settings.hotkey)
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
            SettingsGroup(title: "Shortcut") {
                SettingsRow(
                    symbol: PerchCommand.clipboardHistory.symbol,
                    tint: .orange,
                    title: PerchCommand.clipboardHistory.title,
                    detail: "Open the clipboard history from any app."
                ) {
                    ShortcutRecorderView(
                        slot: .launcher(LauncherItem.command(.clipboardHistory).key),
                        shortcut: $settings.shortcuts[LauncherItem.command(.clipboardHistory).key]
                    )
                }
            }
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

/// One row per activity source: toggle, permission state, and a way to fix a missing permission.
struct ActivitiesSettingsPage: View {
    @Bindable private var settings = AppSettings.shared
    private let sources = ActivitySources.shared
    /// Re-read every second: permissions change in System Settings, outside Perch.
    @State private var permissions: [String: SourcePermission] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageHeader(section: .activities)
            SettingsGroup(title: "Sources") {
                ForEach(Array(sources.all.enumerated()), id: \.offset) { index, source in
                    if index > 0 { SettingsDivider() }
                    sourceRow(source)
                    if sources.isEnabled(source) { options(for: type(of: source).id) }
                }
            }
            Label("Timers, conversions and coding agents always show; they are not sources.", systemImage: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 10)
                .padding(.leading, 4)
        }
        .task {
            while !Task.isCancelled {
                let current = Dictionary(uniqueKeysWithValues: sources.all.map { (type(of: $0).id, $0.permission) })
                if current != permissions { permissions = current }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Extra rows under an enabled source.
    @ViewBuilder
    private func options(for id: String) -> some View {
        switch id {
        case "hud":
            SettingsDivider()
            SettingsRow(
                symbol: "rectangle.slash",
                tint: .secondary,
                title: "Replace system HUD",
                detail: "Hides Apple's volume and brightness overlay by pausing OSDUIHelper. macOS may bring it back after sleep or an update; it returns when Perch quits."
            ) {
                Toggle("Replace system HUD", isOn: $settings.replacesSystemHUD)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        case "call":
            SettingsDivider()
            SettingsRow(
                symbol: "globe",
                tint: .secondary,
                title: "Google Meet controls",
                detail: "Mute, camera and leave for Meet in Chrome. Chrome must allow it: View › Developer › Allow JavaScript from Apple Events."
            ) {
                Toggle("Google Meet controls", isOn: $settings.meetControls)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        case "weather":
            SettingsDivider()
            SettingsRow(
                symbol: "mappin.and.ellipse",
                tint: .secondary,
                title: "City",
                detail: "Leave empty to use this Mac's location."
            ) {
                TextField("Current location", text: $settings.weatherCity)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }
        case "dictation":
            SettingsDivider()
            SettingsRow(
                symbol: "keyboard",
                tint: .secondary,
                title: "Dictation shortcut",
                detail: "Press once to start, again to stop and type the text into the app you are using."
            ) {
                ShortcutRecorderView(slot: .dictation, shortcut: $settings.dictationHotkey)
            }
        default:
            EmptyView()
        }
    }

    private func sourceRow(_ source: any ActivitySource) -> some View {
        let info = type(of: source).info
        let permission = permissions[type(of: source).id] ?? source.permission
        return SettingsRow(symbol: info.symbol, tint: info.tint, title: info.title, detail: info.detail) {
            HStack(spacing: 10) {
                PermissionChip(permission: permission, isEnabled: sources.isEnabled(source))
                Toggle(info.title, isOn: Binding(
                    get: { settings.enabledSources.contains(type(of: source).id) },
                    set: { sources.setEnabled(source, $0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
        }
    }
}

/// Permission state beside a source's toggle; a button when the user has something to do.
private struct PermissionChip: View {
    let permission: SourcePermission
    let isEnabled: Bool

    var body: some View {
        switch permission {
        case .none:
            EmptyView()
        case let .granted(kind):
            chip("\(kind.title) granted", symbol: "checkmark.circle.fill", tint: .green)
        case let .needed(kind):
            if isEnabled, kind == .accessibility {
                Button("Grant \(kind.title)…") { AccessibilityPermission.requestPrompt() }
            } else if isEnabled, kind == .fullDiskAccess {
                // Nothing can prompt for it: the user adds Perch in the pane by hand.
                Button("Open System Settings…") {
                    if let url = kind.settingsURL { NSWorkspace.shared.open(url) }
                }
                .help("Add Perch under Full Disk Access, then come back.")
            } else {
                chip("Needs \(kind.title)", symbol: "lock.fill", tint: .secondary)
            }
        case let .denied(kind):
            Button("Open System Settings…") {
                if let url = kind.settingsURL { NSWorkspace.shared.open(url) }
            }
            .help("\(kind.title) access is off for Perch.")
        }
    }

    private func chip(_ text: String, symbol: String, tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint)
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
