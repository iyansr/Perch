import AppKit
import SwiftUI

/// Frosted results panel under the open surface: chips, results, key hints.
struct CommandPanelView: View {
    @Bindable var model: NotchModel
    let controller: NotchController
    /// The panel is inserted fresh on every open, so this marks when the open animation started.
    @State private var openedAt = Date()

    private static let rowHeight: CGFloat = 36
    private static let rowSpacing: CGFloat = 0
    private static let maxListHeight: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            chips
            if model.scope == .clipboard {
                ClipboardListView(model: model, controller: controller)
                ClipboardFooter(model: model, controller: controller)
            } else {
                Text(model.sectionTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
                list
                footer
            }
        }
        .padding(12)
        .frame(width: NotchGeometry.searchPanelWidth)
        .background {
            VisualEffectBackground()
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.35))
        }
        .shadow(color: .black.opacity(0.3), radius: 30, y: 20)
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { model.panelHeight = $0 }
    }

    private var chips: some View {
        HStack(spacing: 6) {
            ForEach(SearchScope.allCases) { scope in
                let selected = scope == model.scope
                Button(scope.title) { model.scope = scope }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 13)
                    .frame(height: 30)
                    .foregroundStyle(selected ? Color(nsColor: .windowBackgroundColor) : .primary)
                    .background(Capsule().fill(selected ? Color.primary : Color.primary.opacity(0.06)))
            }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var list: some View {
        if model.results.isEmpty {
            Text(emptyMessage)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Self.rowSpacing) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                            ResultRow(
                                result: result,
                                icon: model.icon(for: result),
                                isSelected: index == model.selection
                            )
                            .id(result.id)
                            .onHover { if $0 { model.selection = index } }
                            .onTapGesture { controller.run(result) }
                            .modifier(RowEntrance(index: index, animated: isOpening))
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(height: listHeight)
                .onChange(of: model.selection) { _, selection in
                    guard model.results.indices.contains(selection) else { return }
                    proxy.scrollTo(model.results[selection].id)
                }
            }
        }
    }

    private var emptyMessage: String {
        let hasQuery = !model.query.trimmingCharacters(in: .whitespaces).isEmpty
        switch model.scope {
        case .clipboard: return "" // ClipboardListView draws its own empty states
        case .files: return hasQuery ? "No files match “\(model.query)”" : "Type to search files"
        case .ai: return "Type a question to ask AI"
        case .all, .apps: return hasQuery ? "No results for “\(model.query)”" : "Indexing applications…"
        }
    }

    /// Rows only stagger in as part of the open animation, not while the user types.
    private var isOpening: Bool {
        Date().timeIntervalSince(openedAt) < 0.3
    }

    private var footer: some View {
        HStack {
            Text(model.results.count == 1 ? "1 result" : "\(model.results.count) results")
            Spacer()
            HStack(spacing: 4) {
                KeyCap("↑")
                KeyCap("↓")
                Text("Move").padding(.trailing, 6)
                KeyCap("↵")
                Text("Open").padding(.trailing, 6)
                if case .file = model.selectedResult {
                    KeyCap("⌘↵")
                    Text("Reveal").padding(.trailing, 6)
                }
                KeyCap("esc")
                Text(model.searchReturnsHome ? "Home" : "Close")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .overlay(alignment: .top) { Divider() }
        .padding(.top, 8)
    }

    private var listHeight: CGFloat {
        let count = CGFloat(model.results.count)
        return min(Self.maxListHeight, count * Self.rowHeight + max(0, count - 1) * Self.rowSpacing)
    }
}

extension NotchModel {
    func icon(for result: SearchResult) -> NSImage? {
        switch result {
        case let .app(app): search.icon(for: app)
        case let .file(url): search.fileIcon(for: url)
        default: nil
        }
    }
}

private struct ResultRow: View {
    let result: SearchResult
    let icon: NSImage?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            tile
            Text(result.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(result.kind)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.1) : .clear)
        }
        .contentShape(Rectangle())
    }

    private var tile: some View {
        ResultIcon(result: result, icon: icon, size: 20)
    }
}

/// App/file icon when there is one, otherwise a coloured tile with a symbol for the result kind.
struct ResultIcon: View {
    let result: SearchResult
    let icon: NSImage?
    let size: CGFloat

    var body: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: size, height: size)
        } else {
            let style = tileStyle
            RoundedRectangle(cornerRadius: size / 4, style: .continuous)
                .fill(style.color)
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: style.symbol)
                        .font(.system(size: size / 2, weight: .bold))
                        .foregroundStyle(.white)
                }
        }
    }

    private var tileStyle: (symbol: String, color: Color) {
        switch result {
        case .app: ("app", .gray)
        case .answer: ("equal", Color(red: 0.12, green: 0.62, blue: 0.53))
        case .timer: ("timer", .orange)
        case .web: ("globe", Color(red: 0.04, green: 0.56, blue: 0.84))
        case .file: ("doc", .gray)
        case .clip: ("doc.on.clipboard", .gray)
        case .ask: ("sparkles", .purple)
        }
    }
}

/// `.row` in the prototype: each row rises 8 pt and fades in, staggered after the panel drops.
private struct RowEntrance: ViewModifier {
    let index: Int
    @State private var shown: Bool

    init(index: Int, animated: Bool) {
        self.index = index
        _shown = State(initialValue: !animated)
    }

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 8)
            .onAppear {
                guard !shown else { return }
                withAnimation(NotchMotion.rowIn(index: index)) { shown = true }
            }
    }
}

/// Behind-window blur that stays active even though Perch never becomes the active app.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}
