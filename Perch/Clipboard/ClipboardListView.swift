import AppKit
import SwiftUI

/// Clipboard history, Raycast-style: rows on the left ("Pinned" header, then newest first),
/// the selected clip's preview and details on the right. Mouse hover only highlights;
/// it never moves the selection.
struct ClipboardListView: View {
    let model: NotchModel
    let controller: NotchController
    private let state = ClipboardPanelState.shared

    /// The split grows with the list between room for the detail pane and a Raycast-style cap.
    private static let minSplitHeight: CGFloat = 220
    private static let maxSplitHeight: CGFloat = 340
    private static let sectionHeaderHeight: CGFloat = 27
    private static let listWidth: CGFloat = 250

    private var items: [ClipboardItem] {
        model.results.compactMap {
            if case let .clip(item) = $0 { item } else { nil }
        }
    }

    var body: some View {
        content
            .frame(
                minHeight: state.isFilterOpen ? ClipboardFilterPopover.height + 8 : 0,
                alignment: .top
            )
            .overlay(alignment: .bottomLeading) {
                if state.isFilterOpen {
                    ZStack(alignment: .bottomLeading) {
                        // Click-away layer under the popover.
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { state.isFilterOpen = false }
                        ClipboardFilterPopover()
                            .padding(.leading, 6)
                            .padding(.bottom, 4)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
                    }
                }
            }
        .animation(.easeOut(duration: 0.12), value: state.isFilterOpen)
    }

    @ViewBuilder
    private var content: some View {
        let rows = self.items
        if rows.isEmpty {
            Text(emptyMessage)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
        } else {
            HStack(spacing: 0) {
                list(rows)
                    .frame(width: Self.listWidth)
                Divider()
                    .padding(.horizontal, 10)
                ClipboardDetailView(item: rows.indices.contains(model.selection) ? rows[model.selection] : rows[0])
            }
            .frame(height: splitHeight(rows))
        }
    }

    private func splitHeight(_ rows: [ClipboardItem]) -> CGFloat {
        let headers: CGFloat = rows.first?.isPinned == true ? 2 * Self.sectionHeaderHeight : 0
        let listHeight = CGFloat(rows.count) * ClipboardRow.height + headers
        return min(Self.maxSplitHeight, max(Self.minSplitHeight, listHeight))
    }

    private func list(_ items: [ClipboardItem]) -> some View {
        let hasPinned = items.first?.isPinned == true
        let firstUnpinned = items.firstIndex { !$0.isPinned }

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index == 0, hasPinned { sectionHeader("Pinned") }
                        if index == firstUnpinned, hasPinned { sectionHeader("Recent") }
                        ClipboardRow(
                            item: item,
                            isSelected: index == model.selection,
                            onSelect: { model.selection = index },
                            onActivate: { controller.run(.clip(item)) }
                        )
                        .id(item.id)
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(maxHeight: .infinity)
            .onAppear { scrollToSelection(items, proxy) }
            .onChange(of: model.selection) { scrollToSelection(items, proxy) }
        }
    }

    private func scrollToSelection(_ items: [ClipboardItem], _ proxy: ScrollViewProxy) {
        guard items.indices.contains(model.selection) else { return }
        proxy.scrollTo(items[model.selection].id)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.primary.opacity(0.6))
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyMessage: String {
        let query = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            return state.filter == .all
                ? "No clips match “\(query)”"
                : "No \(state.filter.title.lowercased()) match “\(query)”"
        }
        if state.filter == .all, !AppSettings.shared.clipboardEnabled {
            return "Clipboard history is turned off"
        }
        return state.filter.emptyMessage
    }
}

private struct ClipboardRow: View {
    static let height: CGFloat = 40
    private static let tile: CGFloat = 28

    let item: ClipboardItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onActivate: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            leading
            Text(item.previewText)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.primary.opacity(0.6))
            }
        }
        .frame(height: Self.height)
        .padding(.horizontal, 10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.1 : isHovering ? 0.05 : 0))
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2, perform: onActivate)
        .onTapGesture(perform: onSelect)
    }

    @ViewBuilder
    private var leading: some View {
        switch item.kind {
        case .image:
            if let path = item.imagePath {
                ClipThumbnail(path: path, side: Self.tile)
            } else {
                symbolTile("photo")
            }
        case .file:
            Image(nsImage: ClipboardIcons.shared.file(path: item.fileURLs.first?.path ?? ""))
                .resizable()
                .frame(width: Self.tile - 4, height: Self.tile - 4)
                .frame(width: Self.tile, height: Self.tile)
        case .text:
            switch item.textForm {
            case let .color(hex):
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(ClipboardFormat.color(hex: hex) ?? .clear)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.2))
                    }
                    .frame(width: Self.tile, height: Self.tile)
            case .link: symbolTile("link")
            case .email: symbolTile("envelope")
            case .plain: symbolTile("text.alignleft")
            }
        }
    }

    private func symbolTile(_ name: String) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.primary.opacity(0.1))
            .frame(width: Self.tile, height: Self.tile)
            .overlay {
                Image(systemName: name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.6))
            }
    }
}

/// Row thumbnail from the 256 px derivative.
private struct ClipThumbnail: View {
    let path: String
    let side: CGFloat
    @State private var image: NSImage?

    init(path: String, side: CGFloat) {
        self.path = path
        self.side = side
        _image = State(initialValue: ThumbnailCache.shared.cached(path: path, maxPixel: ThumbnailCache.rowPixels))
    }

    var body: some View {
        ZStack {
            Color.primary.opacity(0.1)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.2))
        }
        .task(id: path) {
            if image == nil {
                image = await ThumbnailCache.shared.image(path: path, maxPixel: ThumbnailCache.rowPixels)
            }
        }
    }
}

