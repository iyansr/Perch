import AppKit

enum ScreenStyle: Equatable {
    /// Built-in display with a camera housing: the surface grows out of the hardware notch.
    case notch
    /// No notch (external display, clamshell): a floating pill at the top centre,
    /// stepped left when the menu bar extras reach under it.
    case island
}

/// Where the surface lives on screen. The panel is a fixed-size transparent window
/// centred on the notch; everything else is laid out inside it.
struct NotchGeometry: Equatable {
    static let windowSize = CGSize(width: 760, height: 620)
    /// iPhone Dynamic Island, idle (126 × 37.33 pt).
    static let islandSize = CGSize(width: 126, height: 37)
    /// iPhone Dynamic Island, compact with a live activity on both sides of the camera.
    static let islandCompactSize = CGSize(width: 250, height: 37)
    static let panelWidth: CGFloat = 480
    /// Clipboard scope: list and detail side by side.
    static let clipboardPanelWidth: CGFloat = 680
    static let panelGap: CGFloat = 10
    /// Room the idle island needs in the menu bar: compact pill plus its hover swell.
    static let islandClearance: CGFloat = islandCompactSize.width + 12
    /// Space kept between the island and the leftmost menu bar extra.
    static let extrasGap: CGFloat = 8

    var style: ScreenStyle
    var screenFrame: CGRect
    /// Hardware notch size, or the idle island size.
    var notchSize: CGSize
    /// Horizontal centre of the notch in screen coordinates.
    var centerX: CGFloat
    /// Distance from the top edge the island hangs from: 0 in the menu bar, the bar's height below it.
    var islandTop: CGFloat = 0

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

    /// Horizontal centre for the island. macOS keeps menu bar extras out of a hardware notch,
    /// but on a notchless display they run under the island, so the island moves left of them
    /// instead, without letting the window leave the screen.
    /// - Parameter extrasEdge: screen x of the leftmost menu bar extra, nil when unknown.
    static func islandCenterX(screenFrame: CGRect, extrasEdge: CGFloat?) -> CGFloat {
        let centred = screenFrame.midX
        guard let extrasEdge else { return centred }
        let clear = extrasEdge - extrasGap - islandClearance / 2
        let leftmost = screenFrame.minX + windowSize.width / 2
        return max(min(centred, clear), leftmost).rounded()
    }
}

/// Follows the primary (menu bar) screen and reports notch vs island, live across lid and display changes.
/// On island screens it also tracks the menu bar extras so the island never covers them.
final class ScreenManager {
    /// Extras come, go and change width (text-based status items), so the island re-checks periodically.
    private static let extrasScanInterval: TimeInterval = 5
    /// Every Nth check queries all apps again, catching extras added after launch; others query known owners only.
    private static let fullScanEvery = 12

    private(set) var geometry: NotchGeometry
    var onChange: ((NotchGeometry) -> Void)?
    /// While true, extras changes do not move the island (e.g. the panel is open or hovered); the next scan catches up.
    var holdsPosition: (() -> Bool)?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var scanTimer: Timer?
    private var isScanning = false
    /// Set by invalidations; makes the next scan query every app, even one arriving mid-scan.
    private var needsFullScan = true
    private var scansUntilFull = 0
    /// Apps that own menu bar extras; nil forces the next scan to query every app.
    private var extrasOwners: [pid_t]?
    private var extras: MenuBarExtras.Reading

    init() {
        extras = AXIsProcessTrusted() ? .readable(edge: nil) : .unreadable
        geometry = Self.currentGeometry(extras: extras)
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { $0.refresh() }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observe(workspace, name) { manager in
                manager.invalidateOwners()
                manager.scanExtras()
            }
        }
        scanTimer = Timer.scheduledTimer(withTimeInterval: Self.extrasScanInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scanExtras() }
        }
    }

    deinit {
        for (center, observer) in observers { center.removeObserver(observer) }
        scanTimer?.invalidate()
    }

    func refresh() {
        invalidateOwners()
        apply(Self.currentGeometry(extras: extras))
        scanExtras()
    }

    /// Apps came or went, or the screens changed: the next scan must query every app.
    private func invalidateOwners() {
        extrasOwners = nil
        needsFullScan = true
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping (ScreenManager) -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observers.append((center, observer))
    }

    private func apply(_ next: NotchGeometry) {
        guard next != geometry else { return }
        geometry = next
        onChange?(next)
    }

    /// Reads the extras off the main thread (Accessibility IPC to other apps), then re-places the island.
    private func scanExtras() {
        guard geometry.style == .island, !isScanning, let screen = NSScreen.screens.first else { return }
        isScanning = true
        if needsFullScan || scansUntilFull == 0 { extrasOwners = nil }
        needsFullScan = false
        scansUntilFull = extrasOwners == nil ? Self.fullScanEvery : scansUntilFull - 1
        let owners = extrasOwners
        let frame = screen.frame
        let menuBarHeight = Self.menuBarHeight(of: screen)
        Task { [weak self] in
            let scan = await Task.detached(priority: .utility) {
                MenuBarExtras.scan(owners: owners, screenFrame: frame, menuBarHeight: menuBarHeight)
            }.value
            guard let self else { return }
            isScanning = false
            // An invalidation that arrived mid-scan wins over this scan's owner list.
            if !needsFullScan { extrasOwners = scan?.owners }
            extras = Self.settle(extras, with: scan)
            if holdsPosition?() != true { apply(Self.currentGeometry(extras: extras)) }
            if needsFullScan { scanExtras() }
        }
    }

    /// Text extras change width all the time; drifts the gap already absorbs keep the old edge so the island doesn't twitch.
    private static func settle(_ current: MenuBarExtras.Reading, with scan: MenuBarExtras.Scan?) -> MenuBarExtras.Reading {
        guard let scan else { return .unreadable }
        if case .readable(let old?) = current, let new = scan.edge, abs(new - old) < NotchGeometry.extrasGap {
            return current
        }
        return .readable(edge: scan.edge)
    }

    private static func menuBarHeight(of screen: NSScreen) -> CGFloat {
        max(screen.frame.maxY - screen.visibleFrame.maxY, NSStatusBar.system.thickness)
    }

    static func currentGeometry(extras: MenuBarExtras.Reading) -> NotchGeometry {
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
        switch extras {
        case .readable(let edge):
            return NotchGeometry(
                style: .island,
                screenFrame: frame,
                notchSize: NotchGeometry.islandSize,
                centerX: NotchGeometry.islandCenterX(screenFrame: frame, extrasEdge: edge)
            )
        case .unreadable:
            // Without Accessibility the extras could be anywhere, so the island hangs below the menu bar instead.
            return NotchGeometry(
                style: .island,
                screenFrame: frame,
                notchSize: NotchGeometry.islandSize,
                centerX: frame.midX,
                islandTop: menuBarHeight(of: screen)
            )
        }
    }
}
