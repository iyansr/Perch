import Foundation

/// One entry in the drop-to-convert action list.
nonisolated enum ConversionAction: String, CaseIterable, Identifiable {
    case png, jpg, webp, heic, resize50, compress

    var id: Self { self }

    var title: String {
        switch self {
        case .png: "PNG"
        case .jpg: "JPG"
        case .webp: "WebP"
        case .heic: "HEIC"
        case .resize50: "Resize 50%"
        case .compress: "Compress"
        }
    }

    var symbol: String {
        switch self {
        case .png: "photo"
        case .jpg: "photo.fill"
        case .webp: "globe"
        case .heic: "camera.aperture"
        case .resize50: "arrow.down.right.and.arrow.up.left"
        case .compress: "arrow.down.right.and.arrow.up.left.circle"
        }
    }

    /// Past-tense verb for the activity detail line ("3 converted", "2 resized", …).
    var pastTense: String {
        switch self {
        case .png, .jpg, .webp, .heic: "converted"
        case .resize50: "resized"
        case .compress: "compressed"
        }
    }

    /// Name suffix; empty for a plain format change.
    var suffix: String {
        switch self {
        case .compress: "-compressed"
        case .resize50: "-50"
        case .png, .jpg, .webp, .heic: ""
        }
    }
}
