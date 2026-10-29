import SwiftUI

/// Fixed-width type filter, opened with ⌘P on the active filter. Drawn inside the panel
/// (not an `NSPopover`) so the search field keeps first responder and ↑ ↓ ↵ esc stay with `NotchController`.
struct ClipboardFilterPopover: View {
    static let width: CGFloat = 200
    static let rowHeight: CGFloat = 28
    static let padding: CGFloat = 6
    static var height: CGFloat {
        CGFloat(ClipFilter.allCases.count) * rowHeight + 2 * padding
    }

    private let state = ClipboardPanelState.shared

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(ClipFilter.allCases.enumerated()), id: \.element) { index, filter in
                row(filter, isCursor: index == state.filterCursor)
                    .onHover { if $0 { state.filterCursor = index } }
                    .onTapGesture { state.apply(filter) }
            }
        }
        .padding(Self.padding)
        .frame(width: Self.width)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.2))
        }
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
    }

    private func row(_ filter: ClipFilter, isCursor: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: filter.symbol)
                .font(.system(size: 12))
                .frame(width: 16)
                .foregroundStyle(.primary.opacity(0.6))
            Text(filter.title)
                .font(.system(size: 13))
            Spacer(minLength: 0)
            if filter == state.filter {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.6))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isCursor ? 0.1 : 0))
        }
        .contentShape(Rectangle())
    }
}
