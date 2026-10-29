import AppKit
import SwiftUI

/// Right-hand pane of the clipboard split: a preview of the selected clip over an "Information" table.
struct ClipboardDetailView: View {
    let item: ClipboardItem

    /// Text previews are capped so layout never measures a 32 k-character string.
    private static let textPreviewLimit = 4_000

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            information
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Preview

    @ViewBuilder
    private var preview: some View {
        switch item.kind {
        case .image:
            if let path = item.imagePath {
                ClipImagePreview(path: path)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .file:
            fileList
        case .text:
            if case let .color(hex) = item.textForm {
                VStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(ClipboardFormat.color(hex: hex) ?? .clear)
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.2))
                        }
                        .frame(width: 96, height: 96)
                    Text(hex)
                        .font(.system(size: 13, design: .monospaced))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(String((item.text ?? "").prefix(Self.textPreviewLimit)))
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollIndicators(.never)
            }
        }
    }

    private var fileList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(item.fileURLs, id: \.self) { url in
                    HStack(spacing: 8) {
                        Image(nsImage: ClipboardIcons.shared.file(path: url.path))
                            .resizable()
                            .frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.lastPathComponent)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Text(url.deletingLastPathComponent().path)
                                .font(.system(size: 11))
                                .foregroundStyle(.primary.opacity(0.6))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }

    // MARK: Information

    private var information: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Information")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.6))
                .padding(.top, 10)
                .padding(.bottom, 2)
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider() }
                infoRow(row)
            }
        }
    }

    private struct InfoRow {
        var label: String
        var value: String
        var icon: NSImage?
    }

    private func infoRow(_ row: InfoRow) -> some View {
        HStack(spacing: 6) {
            Text(row.label)
                .foregroundStyle(.primary.opacity(0.6))
            Spacer(minLength: 8)
            if let icon = row.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 14, height: 14)
            }
            Text(row.value)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 12))
        .frame(height: 26)
    }

    private var rows: [InfoRow] {
        var rows: [InfoRow] = []
        let icons = ClipboardIcons.shared
        if let name = icons.appName(bundleID: item.sourceBundleID) {
            rows.append(InfoRow(label: "Source", value: name, icon: icons.app(bundleID: item.sourceBundleID)))
        }
        rows.append(InfoRow(label: "Type", value: item.kindLabel))
        switch item.kind {
        case .text:
            let text = item.text ?? ""
            rows.append(InfoRow(label: "Characters", value: text.count.formatted()))
            let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            rows.append(InfoRow(label: "Words", value: words.formatted()))
        case .image:
            if let path = item.imagePath {
                if let size = ThumbnailCache.shared.pixelSize(path: path) {
                    rows.append(InfoRow(label: "Dimensions", value: "\(Int(size.width))×\(Int(size.height))"))
                }
                if let bytes = Self.fileSize(path) {
                    rows.append(InfoRow(label: "Size", value: bytes))
                }
            }
        case .file:
            let urls = item.fileURLs
            if urls.count > 1 {
                rows.append(InfoRow(label: "Files", value: urls.count.formatted()))
            } else if let url = urls.first, let bytes = Self.fileSize(url.path) {
                rows.append(InfoRow(label: "Size", value: bytes))
            }
        }
        rows.append(InfoRow(label: "Copied", value: Self.copiedString(item.createdAt)))
        return rows
    }

    private static func fileSize(_ path: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let bytes = attributes[.size] as? Int64
        else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// "Today at 16:56", "Yesterday at 09:12", or "Oct 27 at 18:03".
    private static func copiedString(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today at \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday at \(time)" }
        return "\(date.formatted(.dateTime.month(.abbreviated).day())) at \(time)"
    }
}

/// Selected image clip, fitted into the detail pane from the 900 px derivative.
private struct ClipImagePreview: View {
    let path: String
    @State private var image: NSImage?

    init(path: String) {
        self.path = path
        let cache = ThumbnailCache.shared
        _image = State(
            initialValue: cache.cached(path: path, maxPixel: ThumbnailCache.previewPixels)
                ?? cache.cached(path: path, maxPixel: ThumbnailCache.rowPixels)
        )
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            }
        }
        .task(id: path) {
            image = await ThumbnailCache.shared.image(path: path, maxPixel: ThumbnailCache.previewPixels)
        }
    }
}
