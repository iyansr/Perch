import AppKit
import SwiftUI

/// Display strings and tokens shared by the clipboard views.
extension ClipboardItem {
    /// One-line preview: whitespace collapsed, capped so layout never measures a 32 k-character string.
    var previewText: String {
        switch kind {
        case .text:
            let collapsed = (text ?? "").prefix(240)
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            return collapsed.isEmpty ? "Blank text" : collapsed
        case .file:
            let names = fileURLs.map(\.lastPathComponent)
            guard let first = names.first else { return "File" }
            return names.count > 1 ? "\(first) +\(names.count - 1) more" : first
        case .image:
            guard let imagePath, let size = ThumbnailCache.shared.pixelSize(path: imagePath) else { return "Image" }
            return "Image \(Int(size.width))×\(Int(size.height))"
        }
    }

    /// Right-aligned type label for search-result style listings.
    var kindLabel: String {
        switch kind {
        case .image: "Image"
        case .file: "File"
        case .text:
            switch textForm {
            case .plain: "Text"
            case .link: "Link"
            case .email: "Email"
            case .color: "Color"
            }
        }
    }
}

extension ClipFilter {
    var symbol: String {
        switch self {
        case .all: "tray.full"
        case .text: "text.alignleft"
        case .links: "link"
        case .emails: "envelope"
        case .colors: "paintpalette"
        case .images: "photo"
        case .files: "doc"
        }
    }

    /// Empty-list message for a filter that matches nothing.
    var emptyMessage: String {
        self == .all ? "Clipboard history is empty" : "No \(title.lowercased()) in history"
    }
}

enum ClipboardFormat {
    /// "now", "5m", "3h", "2d": compact enough for a 480 pt row.
    static func relativeTime(from date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86400))d"
        }
    }

    /// `#RGB`, `#RRGGBB` or `#RRGGBBAA` (as produced by `ClipboardItem.textForm`).
    static func color(hex: String) -> Color? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var expanded = digits
        if digits.count == 3 { expanded = digits.map { "\($0)\($0)" }.joined() }
        guard expanded.count == 6 || expanded.count == 8, let value = UInt64(expanded, radix: 16) else { return nil }
        let hasAlpha = expanded.count == 8
        let red = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let green = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let blue = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let alpha = hasAlpha ? Double(value & 0xFF) / 255 : 1
        return Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

/// App and file icons for rows; `NSWorkspace` lookups are not free.
final class ClipboardIcons {
    static let shared = ClipboardIcons()

    private var apps: [String: NSImage] = [:]
    private var names: [String: String] = [:]
    private var misses: Set<String> = []
    private var files: [String: NSImage] = [:]

    func app(bundleID: String?) -> NSImage? {
        if let bundleID, let cached = apps[bundleID] { return cached }
        guard let url = appURL(bundleID: bundleID), let bundleID else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        apps[bundleID] = icon
        return icon
    }

    /// Display name of the source app ("Xcode"), or nil when it is not installed.
    func appName(bundleID: String?) -> String? {
        if let bundleID, let cached = names[bundleID] { return cached }
        guard let url = appURL(bundleID: bundleID), let bundleID else { return nil }
        let name = (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
        names[bundleID] = name
        return name
    }

    private func appURL(bundleID: String?) -> URL? {
        guard let bundleID, !misses.contains(bundleID) else { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            misses.insert(bundleID)
            return nil
        }
        return url
    }

    func file(path: String) -> NSImage {
        if let cached = files[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        files[path] = icon
        return icon
    }
}
