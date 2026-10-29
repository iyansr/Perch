import Foundation

/// Spotlight-backed filename search over the home folder and /Applications.
/// Call `update(query:)` on every keystroke; `onUpdate` fires when new results land.
final class FileSearch {
    static let maxResults = 30
    static let debounce: Duration = .milliseconds(120)

    private(set) var results: [URL] = []
    /// True from the first keystroke of a non-empty query until its results land or it is cancelled.
    private(set) var isSearching = false
    var onUpdate: (() -> Void)?

    private var query: NSMetadataQuery?
    private var currentText = ""
    private var debounceTask: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// No-op when `text` matches the query already running or finished.
    func update(query text: String) {
        guard text != currentText else { return }
        currentText = text
        debounceTask?.cancel()
        stop()
        results = []
        isSearching = !text.isEmpty
        guard !text.isEmpty else { return }

        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.start(text)
        }
    }

    func cancel() {
        debounceTask?.cancel()
        stop()
        currentText = ""
        isSearching = false
        results = []
    }

    private func start(_ text: String) {
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, text)
        query.searchScopes = [NSHomeDirectory(), "/Applications"]
        observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finished(text) }
        }
        self.query = query
        query.start()
    }

    private func stop() {
        query?.stop()
        query = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func finished(_ text: String) {
        guard let query, text == currentText else { return }
        query.disableUpdates()
        let lower = text.lowercased()
        var hits: [(url: URL, rank: Int)] = []
        for case let item as NSMetadataItem in query.results {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  !path.contains("/Library/"), !path.contains("/.") else { continue }
            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent.lowercased()
            let rank = name.hasPrefix(lower) ? 0 : 1
            hits.append((url, rank))
        }
        results = hits
            .sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.url.lastPathComponent.count < $1.url.lastPathComponent.count }
            .prefix(Self.maxResults)
            .map(\.url)
        stop()
        isSearching = false
        onUpdate?()
    }
}
