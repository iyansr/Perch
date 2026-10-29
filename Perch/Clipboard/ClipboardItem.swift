import AppKit
import Foundation

extension NSPasteboard.PasteboardType {
    /// Stamped on every pasteboard write Perch makes; ClipboardMonitor skips items carrying it.
    nonisolated static let perchInternal = NSPasteboard.PasteboardType("com.perch.internal")
}

nonisolated struct ClipboardItem: Identifiable, Hashable {
    enum Kind: String { case text, image, file }
    enum TextForm: Hashable { case plain, link(URL), email(String), color(hex: String) }

    let id: Int64
    var kind: Kind
    /// Text body; for `.file` the absolute path(s), newline-joined.
    var text: String?
    /// Absolute path inside `ClipboardStore.imageDirectory` (`.image` only).
    var imagePath: String?
    var sourceBundleID: String?
    var hash: String
    var pinnedAt: Date?
    var createdAt: Date

    var isPinned: Bool { pinnedAt != nil }

    /// `.file` rows only; `[]` otherwise.
    var fileURLs: [URL] {
        guard kind == .file, let text else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { URL(fileURLWithPath: String($0)) }
    }

    /// Derived from `text` on demand, never stored.
    var textForm: TextForm {
        guard kind == .text, let text else { return .plain }
        return Self.classify(text)
    }

    static func classify(_ raw: String) -> TextForm {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2048,
              !trimmed.contains(where: { $0.isWhitespace })
        else { return .plain }

        if let hex = colorHex(trimmed) { return .color(hex: hex) }
        if isEmail(trimmed) { return .email(trimmed) }
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(), ["http", "https", "ftp"].contains(scheme),
           let host = url.host(), !host.isEmpty {
            return .link(url)
        }
        return .plain
    }

    /// `#RGB`, `#RRGGBB` or `#RRGGBBAA`; returned uppercased with the `#`.
    private static func colorHex(_ s: String) -> String? {
        guard s.hasPrefix("#") else { return nil }
        let digits = s.dropFirst()
        guard [3, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + digits.uppercased()
    }

    private static func isEmail(_ s: String) -> Bool {
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let labels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { !$0.isEmpty } && (labels.last?.count ?? 0) >= 2
    }
}

nonisolated enum ClipFilter: String, CaseIterable, Identifiable {
    case all, text, links, emails, colors, images, files

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All"
        case .text: "Text"
        case .links: "Links"
        case .emails: "Emails"
        case .colors: "Colors"
        case .images: "Images"
        case .files: "Files"
        }
    }

    /// `.text` matches every text row, including links, emails and colors.
    func matches(_ item: ClipboardItem) -> Bool {
        switch self {
        case .all: true
        case .text: item.kind == .text
        case .images: item.kind == .image
        case .files: item.kind == .file
        case .links:
            if case .link = item.textForm { true } else { false }
        case .emails:
            if case .email = item.textForm { true } else { false }
        case .colors:
            if case .color = item.textForm { true } else { false }
        }
    }
}
