import Foundation
import Observation

/// UI state of the Clipboard chip: type filter, filter popover, clear-history confirm and the footer HUD.
@Observable
final class ClipboardPanelState {
    static let shared = ClipboardPanelState()

    /// Re-queries the list; wired by `NotchController`.
    @ObservationIgnored var onFilterChange: (() -> Void)?

    var filter: ClipFilter = .all {
        didSet { if filter != oldValue { onFilterChange?() } }
    }
    var isFilterOpen = false
    /// Highlighted row of the open filter popover.
    var filterCursor = 0
    var isConfirmingClear = false
    /// Short message in the footer (e.g. "File no longer exists"); nil when hidden.
    private(set) var notice: String?

    @ObservationIgnored private var noticeToken = 0

    /// Fresh panel: no filter, nothing open. The caller refreshes results afterwards.
    func reset() {
        let previous = onFilterChange
        onFilterChange = nil
        filter = .all
        onFilterChange = previous
        isFilterOpen = false
        isConfirmingClear = false
        notice = nil
    }

    func openFilter() {
        filterCursor = ClipFilter.allCases.firstIndex(of: filter) ?? 0
        isConfirmingClear = false
        isFilterOpen = true
    }

    func toggleFilter() {
        if isFilterOpen { isFilterOpen = false } else { openFilter() }
    }

    func moveFilterCursor(by delta: Int) {
        let count = ClipFilter.allCases.count
        filterCursor = min(max(filterCursor + delta, 0), count - 1)
    }

    func apply(_ choice: ClipFilter) {
        isFilterOpen = false
        filter = choice
    }

    func showNotice(_ text: String, duration: TimeInterval = 2) {
        noticeToken += 1
        let token = noticeToken
        notice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, noticeToken == token else { return }
            notice = nil
        }
    }

    /// Calls `refresh` whenever the store changes (new copy, pin, promote, delete), re-arming itself.
    func observeStore(_ refresh: @escaping () -> Void) {
        withObservationTracking {
            _ = ClipboardStore.shared.revision
        } onChange: { [weak self] in
            Task { @MainActor in
                refresh()
                self?.observeStore(refresh)
            }
        }
    }
}
