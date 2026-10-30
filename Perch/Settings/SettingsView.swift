import AppKit
import SwiftUI

enum SettingsSection: CaseIterable, Identifiable {
    case general
    case clipboard
    case activities
    case agents
    case shortcuts
    case permissions
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .clipboard: "Clipboard"
        case .activities: "Activities"
        case .agents: "Agents"
        case .shortcuts: "Shortcuts"
        case .permissions: "Permissions"
        case .about: "About"
        }
    }

    /// Line under the page title; About has its own header.
    var subtitle: String {
        switch self {
        case .general: "How you open Perch and how it sounds."
        case .clipboard: "Keep what you copy and paste it again later."
        case .activities: "What else can show up beside the notch."
        case .agents: "See when Claude Code or Codex needs your input or finishes."
        case .shortcuts: "Choose what appears in the launcher and assign global shortcuts."
        case .permissions: "Access Perch needs to work with other apps."
        case .about: ""
        }
    }

    var symbol: String {
        switch self {
        case .general: "switch.2"
        case .clipboard: "doc.on.clipboard.fill"
        case .activities: "waveform"
        case .agents: "sparkles"
        case .shortcuts: "keyboard.fill"
        case .permissions: "lock.shield.fill"
        case .about: "info"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .clipboard: .orange
        case .activities: .indigo
        case .agents: .purple
        case .shortcuts: .teal
        case .permissions: .blue
        case .about: .pink
        }
    }
}

/// Sidebar of sections on the left, the selected page on the right.
struct SettingsView: View {
    @State private var section: SettingsSection = .general

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $section)
                .frame(width: 220)
            Divider()
            ScrollView {
                page
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.top, 28)
                    .padding(.bottom, 24)
            }
            .id(section) // each page starts scrolled to the top
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .ignoresSafeArea()
        .frame(minWidth: 680, minHeight: 460)
        // No main menu in an accessory app, so ⌘W needs its own binding.
        .background {
            Button("Close") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: .command)
                .hidden()
        }
    }

    @ViewBuilder
    private var page: some View {
        switch section {
        case .general: GeneralSettingsPage()
        case .clipboard: ClipboardSettingsPage()
        case .activities: ActivitiesSettingsPage()
        case .agents: AgentsSettingsPage()
        case .shortcuts: ShortcutsSettingsPage()
        case .permissions: PermissionsSettingsPage()
        case .about: AboutSettingsPage()
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selection: SettingsSection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SettingsSection.allCases) { section in
                Button { selection = section } label: {
                    HStack(spacing: 10) {
                        SectionIcon(section: section)
                        Text(section.title)
                            .font(.system(size: 13))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 34)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(selection == section ? 0.1 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 52) // clears the traffic lights
        .frame(maxHeight: .infinity)
        .background { VisualEffectBackground(material: .sidebar) }
    }
}

/// System Settings–style tile: white glyph on a tinted rounded square.
private struct SectionIcon: View {
    let section: SettingsSection

    var body: some View {
        Image(systemName: section.symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(section.tint.gradient)
            }
    }
}

// MARK: - Building blocks

/// Page title and subtitle at the top of a section.
struct SettingsPageHeader: View {
    let section: SettingsSection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(section.title)
                .font(.system(size: 22, weight: .bold))
            Text(section.subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 8)
    }
}

/// Captioned rounded card; separate rows with `SettingsDivider`.
struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 0) { content }
                .background { shape.fill(Color.primary.opacity(0.04)) }
                .overlay { shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 1) }
        }
        .padding(.top, 16)
    }
}

/// Icon, title and description on the left; the control on the right.
struct SettingsRow<Accessory: View>: View {
    let symbol: String
    var tint: Color = .accentColor
    let title: String
    let detail: String
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            accessory
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

/// Hairline between rows, inset to the row titles.
struct SettingsDivider: View {
    var body: some View {
        Divider().padding(.leading, 48)
    }
}
