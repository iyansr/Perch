import CoreGraphics
import Foundation
import Observation

/// The surface's three states. Every exit returns to `.idle`.
enum NotchState: Equatable {
    /// Ambient pill: hardware notch or island, plus the live-activity slot.
    case idle
    /// Hover peek at activity details.
    case glance
    /// Command panel with search field and results.
    case open
}

/// Size and corner shape of the black surface for the current state.
struct ShapeMetrics: Equatable {
    var size: CGSize
    /// Distance from the top screen edge.
    var top: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat
}

@Observable
final class NotchModel {
    static let earWidth: CGFloat = 44
    static let searchRowHeight: CGFloat = 44
    static let glanceRowHeight: CGFloat = 52
    static let glanceMaxRows = 3

    var geometry: NotchGeometry
    var state: NotchState = .idle
    var isHovering = false
    var query = "" {
        didSet { if query != oldValue { refreshResults() } }
    }
    var scope: SearchScope = .all {
        didSet { if scope != oldValue { refreshResults() } }
    }
    var selection = 0
    private(set) var results: [SearchResult] = []
    /// Measured height of the results panel; used for click-outside hit testing.
    var panelHeight: CGFloat = 0

    @ObservationIgnored let activities: ActivityCenter
    @ObservationIgnored let search: SearchEngine

    init(geometry: NotchGeometry, activities: ActivityCenter, search: SearchEngine) {
        self.geometry = geometry
        self.activities = activities
        self.search = search
    }

    // MARK: Search

    var sectionTitle: String {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { return "Top hits" }
        return search.hasRecents ? "Recent" : "Applications"
    }

    var selectedResult: SearchResult? {
        results.indices.contains(selection) ? results[selection] : nil
    }

    func resetSearch() {
        query = ""
        scope = .all
        refreshResults()
    }

    func refreshResults() {
        results = search.results(for: query, scope: scope)
        selection = 0
    }

    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + delta, 0), results.count - 1)
    }

    // MARK: Layout

    var shape: ShapeMetrics {
        let notch = geometry.notchSize
        let activityCount = activities.items.count
        let hover: CGFloat = isHovering ? 1 : 0

        switch (geometry.style, state) {
        case (.notch, .open):
            return ShapeMetrics(
                size: CGSize(width: NotchGeometry.panelWidth, height: notch.height + Self.searchRowHeight),
                top: 0, topRadius: 0, bottomRadius: 22
            )
        case (.island, .open):
            return ShapeMetrics(
                size: CGSize(width: NotchGeometry.panelWidth, height: Self.searchRowHeight),
                top: 8, topRadius: Self.searchRowHeight / 2, bottomRadius: Self.searchRowHeight / 2
            )
        case (.notch, .glance) where activityCount > 0:
            return ShapeMetrics(
                size: CGSize(width: 400, height: notch.height + glanceContentHeight),
                top: 0, topRadius: 0, bottomRadius: 24
            )
        case (.island, .glance) where activityCount > 0:
            return ShapeMetrics(
                size: CGSize(width: 400, height: glanceContentHeight),
                top: 6, topRadius: 22, bottomRadius: 22
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
        if state == .open {
            rect = rect.union(CGRect(
                x: (width - NotchGeometry.panelWidth) / 2,
                y: panelTop,
                width: NotchGeometry.panelWidth,
                height: panelHeight
            ))
        }
        return rect.insetBy(dx: -4, dy: -4)
    }

    private var glanceContentHeight: CGFloat {
        CGFloat(min(activities.items.count, Self.glanceMaxRows)) * Self.glanceRowHeight + 16
    }
}
