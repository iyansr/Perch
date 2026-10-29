import AppKit

enum ScreenStyle: Equatable {
    /// Built-in display with a camera housing: the surface grows out of the hardware notch.
    case notch
    /// No notch (external display, clamshell): a floating pill at the top centre.
    case island
}

/// Where the surface lives on screen. The panel is a fixed-size transparent window
/// centred on the notch; everything else is laid out inside it.
struct NotchGeometry: Equatable {
    static let windowSize = CGSize(width: 680, height: 620)
    /// iPhone Dynamic Island, idle (126 × 37.33 pt).
    static let islandSize = CGSize(width: 126, height: 37)
    /// iPhone Dynamic Island, compact with a live activity on both sides of the camera.
    static let islandCompactSize = CGSize(width: 250, height: 37)
    static let panelWidth: CGFloat = 480
    static let panelGap: CGFloat = 10

    var style: ScreenStyle
    var screenFrame: CGRect
    /// Hardware notch size, or the idle island size.
    var notchSize: CGSize
    /// Horizontal centre of the notch in screen coordinates.
    var centerX: CGFloat

    var windowFrame: CGRect {
        CGRect(
            x: (centerX - Self.windowSize.width / 2).rounded(),
            y: screenFrame.maxY - Self.windowSize.height,
            width: Self.windowSize.width,
            height: Self.windowSize.height
        )
    }

    /// Converts a rect in window content coordinates (top-left origin) to screen coordinates.
    func screenRect(fromWindowRect rect: CGRect) -> CGRect {
        let frame = windowFrame
        return CGRect(x: frame.minX + rect.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// Follows the primary (menu bar) screen and reports notch vs island, live across lid and display changes.
final class ScreenManager {
    private(set) var geometry: NotchGeometry
    var onChange: ((NotchGeometry) -> Void)?
    private var observer: NSObjectProtocol?

    init() {
        geometry = Self.currentGeometry()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func refresh() {
        let next = Self.currentGeometry()
        guard next != geometry else { return }
        geometry = next
        onChange?(next)
    }

    static func currentGeometry() -> NotchGeometry {
        guard let screen = NSScreen.screens.first else {
            let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
            return NotchGeometry(style: .island, screenFrame: frame, notchSize: NotchGeometry.islandSize, centerX: frame.midX)
        }
        let frame = screen.frame
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = frame.width - left.width - right.width
            return NotchGeometry(
                style: .notch,
                screenFrame: frame,
                notchSize: CGSize(width: width, height: screen.safeAreaInsets.top),
                centerX: frame.minX + left.width + width / 2
            )
        }
        return NotchGeometry(style: .island, screenFrame: frame, notchSize: NotchGeometry.islandSize, centerX: frame.midX)
    }
}
