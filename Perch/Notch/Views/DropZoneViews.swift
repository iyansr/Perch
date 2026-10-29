import AppKit
import SwiftUI

/// Inside the black surface while a file drag is under way: "Drop to convert", or why the drop is refused.
struct DropTargetContent: View {
    let drop: DropSession
    let topInset: CGFloat

    var body: some View {
        let refused = !drop.acceptsDrop
        let tint: Color = refused ? Color(red: 1, green: 0.42, blue: 0.4) : .white
        let outline = RoundedRectangle(cornerRadius: 18, style: .continuous)

        HStack(spacing: 8) {
            Image(systemName: refused ? "photo.badge.exclamationmark" : "arrow.down.circle.fill")
                .font(.system(size: 14, weight: .semibold))
            Text(refused ? "Images only in v0.1" : "Drop to convert")
                .font(.system(size: 14, weight: .semibold))
        }
        .foregroundStyle(tint.opacity(drop.isHighlighted ? 1 : 0.7))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            outline.fill(tint.opacity(drop.isHighlighted ? 0.16 : 0.05))
        }
        .overlay {
            outline.strokeBorder(
                tint.opacity(drop.isHighlighted ? 0.9 : 0.3),
                style: StrokeStyle(lineWidth: 1.5, dash: drop.isHighlighted ? [] : [5, 4])
            )
        }
        .padding(8)
        .padding(.top, topInset)
    }
}

/// Header of the black surface once files are dropped; mirrors the search row's footprint.
struct DropChoosingHeader: View {
    let drop: DropSession
    let topInset: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            KeyCap("esc", dark: true)
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: NotchModel.searchRowHeight)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.top, topInset)
    }

    private var title: String {
        if drop.urls.count == 1, let url = drop.urls.first { return "Convert \(url.lastPathComponent)" }
        return "Convert \(drop.urls.count) images"
    }
}

/// Frosted action list under the surface: one row per `ConversionAction`.
struct DropActionPanel: View {
    let model: NotchModel
    let controller: NotchController
    /// Inserted fresh on every drop, so this marks when the open animation started.
    @State private var openedAt = Date()

    private static let rowHeight: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Convert to")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 6)

            VStack(spacing: 0) {
                ForEach(Array(ConversionAction.allCases.enumerated()), id: \.element) { index, action in
                    DropActionRow(action: action, isSelected: index == model.drop?.selection)
                        .onHover { if $0 { controller.dropZone.select(index) } }
                        .onTapGesture { controller.dropZone.choose(action) }
                        .modifier(DropRowEntrance(index: index, animated: isOpening))
                }
            }

            footer
        }
        .padding(12)
        .frame(width: NotchGeometry.panelWidth)
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

    private var isOpening: Bool {
        Date().timeIntervalSince(openedAt) < 0.3
    }

    private var footer: some View {
        HStack {
            Text(model.drop.map { $0.urls.count == 1 ? "1 image" : "\($0.urls.count) images" } ?? "")
            Spacer()
            HStack(spacing: 4) {
                KeyCap("↑")
                KeyCap("↓")
                Text("Move").padding(.trailing, 6)
                KeyCap("↵")
                Text("Convert").padding(.trailing, 6)
                KeyCap("esc")
                Text("Close")
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
}

private struct DropActionRow: View {
    let action: ConversionAction
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.accentColor)
                .frame(width: 20, height: 20)
                .overlay {
                    Image(systemName: action.symbol)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            Text(action.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.1) : .clear)
        }
        .contentShape(Rectangle())
    }

    private var detail: String {
        switch action {
        case .png: "Lossless"
        case .jpg: "Quality 85"
        case .webp: "Quality 80"
        case .heic: "Quality 80"
        case .resize50: "Half the pixel size"
        case .compress: "Same format, smaller file"
        }
    }
}

/// Each row rises 8 pt and fades in, staggered after the panel drops (same cadence as the result rows).
private struct DropRowEntrance: ViewModifier {
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
