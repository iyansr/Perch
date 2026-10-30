import CoreGraphics
import Foundation
import Observation

/// The surface's states. Every exit returns to `.idle`.
enum NotchState: Equatable {
    /// Ambient pill: hardware notch or island, plus the live-activity slot.
    case idle
    /// Hover peek at activity details.
    case glance
    /// Clicking the notch: Home modules (activity, timer, clipboard, search, convert).
    case home
    /// Command panel with search field and results. Opened by the hotkey, a Home module, or typing in Home.
    case open
    /// First-run flow; the surface is sized like `.open`.
    case onboarding
    /// A file drag is under way: the "Drop to convert" target, then the conversion action list after a drop.
    case dropZone
}

/// The view inside `.home`: the module grid, or one module zoomed into its detail.
enum HomePage: Equatable {
    case modules
    case activity
}

/// Size and corner shape of the black surface for the current state.
struct ShapeMetrics: Equatable {
    var size: CGSize
    /// Distance from the top screen edge.
    var top: CGFloat
    /// Convex radius of the top corners (island pill).
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    /// Concave flare where the top edge meets the screen edge, like the hardware notch's corners.
    /// Drawn outside `size.width`, so content keeps its full width.
    var shoulder: CGFloat = 0
}

@Observable
final class NotchModel {
    static let earWidth: CGFloat = 44
    /// Concave top-corner flare of the expanded notch surface, matching the hardware notch's own corners.
    static let expandedShoulder: CGFloat = 10
    static let searchRowHeight: CGFloat = 44
    /// Search row of the open command surface; taller than the other rows so the fade has room.
    static let openRowHeight: CGFloat = 64
    static let glanceRowHeight: CGFloat = 52
    static let glanceMaxRows = 3
    /// Width of the collapsed surface while the post-onboarding hint shows.
    static let hintWidth: CGFloat = 300

    var geometry: NotchGeometry
    var state: NotchState = .idle
    var isHovering = false
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            if mode == .root, query.lowercased().hasPrefix("clip ") {
                mode = .clipboard
                modeReturnsToRoot = true
                query = String(query.dropFirst(5)) // no observer re-entry inside didSet
            }
            refreshResults()
        }
    }
    /// Root list, or the command the user opened from it (Clipboard History, Search Files).
    private(set) var mode: SearchMode = .root
    /// The mode was opened from the root list, so esc steps back there instead of leaving search.
    private(set) var modeReturnsToRoot = false
    var selection = 0
    private(set) var results: [SearchResult] = []
    /// Search work still in flight (Spotlight query, first app scan); drives the circulating glow.
    private(set) var isLoading = false
    /// Measured height of the results panel; used for click-outside hit testing.
    var panelHeight: CGFloat = 0
    /// Name of the app that had focus when the panel opened; paste targets it.
    var pasteTargetName: String?
    /// First-run flow behind `.onboarding`. Kept after the card closes so its exit transition has content.
    var onboarding: OnboardingState?
    /// Drag/drop session behind `.dropZone`. Kept after the zone closes so its exit transition has content.
    var drop: DropSession?
    /// Short message shown in the collapsed surface (e.g. "Press ⌥Space anytime"); nil when hidden.
    var hint: String?
    /// Which Home view is showing; Home always opens on `.modules`.
    var homePage: HomePage = .modules
    /// Measured height of the Home content below the notch; sizes the surface in `.home`.
    var homeContentHeight: CGFloat = 320
    /// Search was opened from Home (module or typing), so esc steps back to Home instead of closing.
    var searchReturnsHome = false
    /// Bumps to play the idle pill's pulse without an activity finishing.
    private(set) var helloTick = 0

    @ObservationIgnored let activities: ActivityCenter
    @ObservationIgnored let search: SearchEngine

    init(geometry: NotchGeometry, activities: ActivityCenter, search: SearchEngine) {
        self.geometry = geometry
        self.activities = activities
        self.search = search
    }

    // MARK: Search

    var selectedResult: SearchResult? {
        results.indices.contains(selection) ? results[selection] : nil
    }

    /// The results panel drops in as soon as search opens, listing recent apps and commands before any typing.
    var showsResults: Bool {
        state == .open
    }

    /// Fresh search in `mode`, as when the panel opens.
    func resetSearch(mode: SearchMode = .root) {
        setMode(mode, returnsToRoot: false)
    }

    /// Opens a command's mode from the root list, optionally carrying a query over (the Search Files fallback row).
    func push(_ mode: SearchMode, query: String = "") {
        setMode(mode, returnsToRoot: true, query: query)
    }

    func popToRoot() {
        setMode(.root, returnsToRoot: false)
    }

    /// Sets the query for the new mode (empty by default) and refreshes once.
    private func setMode(_ newMode: SearchMode, returnsToRoot: Bool, query newQuery: String = "") {
        mode = newMode
        modeReturnsToRoot = returnsToRoot
        if query == newQuery { refreshResults() } else { query = newQuery }
    }

    /// - Parameter keepingSelection: after a store change, stay on the same row when it still exists.
    func refreshResults(keepingSelection: Bool = false) {
        let previous = keepingSelection ? selectedResult?.id : nil
        results = search.results(for: query, mode: mode)
        isLoading = search.isBusy
        selection = previous.flatMap { id in results.firstIndex { $0.id == id } } ?? defaultSelection
    }

    /// Clipboard lands on the newest unpinned row, below the "Pinned" header; everything else on the first row.
    private var defaultSelection: Int {
        guard mode == .clipboard else { return 0 }
        return results.firstIndex { result in
            if case let .clip(item) = result { !item.isPinned } else { false }
        } ?? 0
    }

    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + delta, 0), results.count - 1)
    }

    func pulse() {
        helloTick += 1
    }

    // MARK: Layout

    var shape: ShapeMetrics {
        let notch = geometry.notchSize
        let activityCount = activities.items.count
        let hover: CGFloat = isHovering ? 1 : 0

        switch (geometry.style, state) {
        case (_, .dropZone):
            return dropZoneShape
        case (.notch, .home):
            return ShapeMetrics(
                size: CGSize(width: NotchGeometry.panelWidth, height: notch.height + homeContentHeight),
                top: 0, topRadius: 0, bottomRadius: 24, shoulder: Self.expandedShoulder
            )
        case (.island, .home):
            return ShapeMetrics(
                size: CGSize(width: NotchGeometry.panelWidth, height: homeContentHeight),
                top: 6, topRadius: 24, bottomRadius: 24
            )
        case (.notch, .open):
            return ShapeMetrics(
                size: CGSize(width: NotchGeometry.searchPanelWidth, height: notch.height + Self.openRowHeight),
                top: 0, topRadius: 0, bottomRadius: 22, shoulder: Self.expandedShoulder
            )
        case (.island, .open):
            return ShapeMetrics(
                size: CGSize(width: NotchGeometry.searchPanelWidth, height: Self.openRowHeight),
                top: 6, topRadius: Self.openRowHeight / 2, bottomRadius: Self.openRowHeight / 2
            )
        case (.notch, .onboarding):
            return ShapeMetrics(
                size: CGSize(width: NotchGeometry.panelWidth, height: notch.height + Self.searchRowHeight),
                top: 0, topRadius: 0, bottomRadius: 22, shoulder: Self.expandedShoulder
            )
        case (.island, .onboarding):
            return ShapeMetrics(
                size: CGSize(width: NotchGeometry.panelWidth, height: Self.searchRowHeight),
                top: 8, topRadius: Self.searchRowHeight / 2, bottomRadius: Self.searchRowHeight / 2
            )
        case (.notch, .glance) where activityCount > 0:
            return ShapeMetrics(
                size: CGSize(width: 400, height: notch.height + glanceContentHeight),
                top: 0, topRadius: 0, bottomRadius: 24, shoulder: Self.expandedShoulder
            )
        case (.island, .glance) where activityCount > 0:
            return ShapeMetrics(
                size: CGSize(width: 400, height: glanceContentHeight),
                top: 6, topRadius: 22, bottomRadius: 22
            )
        case (.notch, .idle) where hint != nil:
            return ShapeMetrics(
                size: CGSize(width: Self.hintWidth, height: notch.height + Self.searchRowHeight),
                top: 0, topRadius: 0, bottomRadius: 22, shoulder: Self.expandedShoulder
            )
        case (.island, .idle) where hint != nil:
            return ShapeMetrics(
                size: CGSize(width: Self.hintWidth, height: Self.searchRowHeight),
                top: 8, topRadius: Self.searchRowHeight / 2, bottomRadius: Self.searchRowHeight / 2
            )
        case (.notch, _):
            let ears = activityCount > 0 ? 2 * Self.earWidth : 0
            return ShapeMetrics(
                size: CGSize(width: notch.width + ears + 16 * hover, height: notch.height + 4 * hover),
                top: 0, topRadius: 0, bottomRadius: 12 + 2 * hover
            )
        case (.island, _):
            // Same pill as iPhone's Dynamic Island: capsule radius, widens for a live activity, swells on hover.
            let base = activityCount > 0 ? NotchGeometry.islandCompactSize : notch
            let size = CGSize(width: base.width + 12 * hover, height: base.height + 4 * hover)
            return ShapeMetrics(size: size, top: 5, topRadius: size.height / 2, bottomRadius: size.height / 2)
        }
    }

    var panelTop: CGFloat {
        let shape = shape
        return shape.top + shape.size.height + NotchGeometry.panelGap
    }

    /// Area (window coordinates, top-left origin) that should receive the mouse.
    var interactiveRect: CGRect {
        let shape = shape
        let width = NotchGeometry.windowSize.width
        var rect = CGRect(
            x: (width - shape.size.width) / 2,
            y: 0, // include the gap above the island so the very top edge counts
            width: shape.size.width,
            height: shape.top + shape.size.height
        )
        if showsResults || state == .onboarding {
            let panelWidth = showsResults ? NotchGeometry.searchPanelWidth : NotchGeometry.panelWidth
            rect = rect.union(CGRect(
                x: (width - panelWidth) / 2,
                y: panelTop,
                width: panelWidth,
                height: panelHeight
            ))
        }
        if state == .dropZone, let drop {
            if drop.phase == .choosing {
                rect = rect.union(CGRect(
                    x: (width - NotchGeometry.panelWidth) / 2,
                    y: panelTop,
                    width: NotchGeometry.panelWidth,
                    height: panelHeight
                ))
            } else {
                rect = rect.union(Self.dropBand(windowWidth: width))
            }
        }
        return rect.insetBy(dx: -4, dy: -4)
    }

    private var glanceContentHeight: CGFloat {
        CGFloat(min(activities.items.count, Self.glanceMaxRows)) * Self.glanceRowHeight + 16
    }
}
