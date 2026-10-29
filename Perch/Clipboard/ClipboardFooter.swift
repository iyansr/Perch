import SwiftUI

/// Filter, "Clear history", and the "Paste to <App>" action under the clipboard split.
struct ClipboardFooter: View {
    let model: NotchModel
    let controller: NotchController
    private let state = ClipboardPanelState.shared

    var body: some View {
        HStack(spacing: 6) {
            if state.isConfirmingClear {
                confirmClear
                Spacer(minLength: 0)
            } else {
                clearButton
                filterButton
                Spacer(minLength: 8)
                trailing
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.primary.opacity(0.6))
        .padding(.horizontal, 2)
        .padding(.top, 6)
        .overlay(alignment: .top) { Divider() }
        .padding(.top, 8)
    }

    private var clearButton: some View {
        Button {
            state.isFilterOpen = false
            state.isConfirmingClear = true
        } label: {
            Label("Clear history", systemImage: "trash")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(BarButtonStyle())
    }

    private var confirmClear: some View {
        HStack(spacing: 6) {
            Text("Clear history? Pinned items stay.")
                .padding(.leading, 6)
            Button("Clear") {
                state.isConfirmingClear = false
                ClipboardStore.shared.clearHistory()
                state.showNotice("History cleared")
            }
            .buttonStyle(BarButtonStyle(tint: .red))
            Button("Cancel") { state.isConfirmingClear = false }
                .buttonStyle(BarButtonStyle())
        }
    }

    private var filterButton: some View {
        Button { state.toggleFilter() } label: {
            Label(state.filter.title, systemImage: state.filter.symbol)
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(BarButtonStyle(isActive: state.filter != .all))
        .help("Filter by type (⌘P)")
    }

    @ViewBuilder
    private var trailing: some View {
        if let notice = state.notice {
            Text(notice)
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(1)
                .transition(.opacity)
        } else if case let .clip(item) = model.selectedResult {
            HStack(spacing: 10) {
                hint("⌘↵", "Copy")
                hint("⌘.", item.isPinned ? "Unpin" : "Pin")
                pasteButton(item)
            }
        }
    }

    /// Primary action: pastes into the app that had focus when the panel opened.
    private func pasteButton(_ item: ClipboardItem) -> some View {
        Button { controller.run(.clip(item)) } label: {
            HStack(spacing: 6) {
                Text(pasteLabel)
                    .lineLimit(1)
                KeycapChip("↵")
            }
            .foregroundStyle(.primary)
        }
        .buttonStyle(BarButtonStyle())
    }

    /// Without Accessibility, ↵ only copies (`Paster.canPaste`), so the label says so.
    private var pasteLabel: String {
        guard AccessibilityPermission.isTrusted else { return "Copy" }
        return model.pasteTargetName.map { "Paste to \($0)" } ?? "Paste"
    }

    private func hint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            KeycapChip(keys)
            Text(label)
        }
    }
}

/// Keycap chip, `.filled` style: 18 pt tall, 6 pt radius, 10 % control surface.
struct KeycapChip: View {
    let label: String

    init(_ label: String) {
        self.label = label
    }

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.primary.opacity(0.8))
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18, maxHeight: 18)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.1))
            }
    }
}

/// 28 pt bar control: bare until hovered, then the 10 % control surface (8 pt radius).
struct BarButtonStyle: ButtonStyle {
    var tint: Color?
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        BarButtonBody(configuration: configuration, tint: tint, isActive: isActive)
    }

    private struct BarButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color?
        let isActive: Bool
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint ?? (isActive ? Color.primary : Color.primary.opacity(0.6)))
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.15 : isHovering || isActive ? 0.1 : 0))
                }
                .contentShape(Rectangle())
                .onHover { isHovering = $0 }
        }
    }
}
