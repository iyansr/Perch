import AppKit

/// Chips at the top of the command panel; ⌘1… selects by position.
enum SearchScope: Int, CaseIterable, Identifiable {
    case all, apps

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .apps: "Apps"
        }
    }
}

enum SearchResult: Identifiable, Equatable {
    case app(AppEntry)
    /// Inline math or unit answer; ↵ copies `value`.
    case answer(expression: String, value: String)
    case timer(TimeInterval)
    case web(String)

    var id: String {
        switch self {
        case let .app(app): "app:\(app.url.path)"
        case let .answer(expression, _): "answer:\(expression)"
        case let .timer(duration): "timer:\(duration)"
        case let .web(query): "web:\(query)"
        }
    }

    var title: String {
        switch self {
        case let .app(app): app.name
        case let .answer(expression, value): "\(expression) = \(value)"
        case let .timer(duration): "Start \(TimerCommand.label(for: duration)) timer"
        case let .web(query): "Search the web for “\(query)”"
        }
    }

    /// Right-aligned type label, like Spotlight/Raycast ("Application", "Command").
    var kind: String {
        switch self {
        case .app: "Application"
        case .answer: "Copy Result"
        case .timer: "Command"
        case .web: "Web Search"
        }
    }
}

final class SearchEngine {
    private static let recentsKey = "perch.recentApps"
    private static let maxRecents = 8

    let index = AppIndex()
    private var icons: [URL: NSImage] = [:]
    private var recentPaths: [String]

    init() {
        recentPaths = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
        index.refreshIfStale()
    }

    var hasRecents: Bool { !recentApps.isEmpty }

    func results(for rawQuery: String, scope: SearchScope) -> [SearchResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            let recents = recentApps
            return (recents.isEmpty ? Array(index.apps.prefix(Self.maxRecents)) : recents).map(SearchResult.app)
        }

        var results: [SearchResult] = []
        if scope == .all {
            if let duration = TimerCommand.parse(query) {
                results.append(.timer(duration))
            }
            if let converted = UnitConverter.convert(query) {
                let value = Calculator.format(converted.value, maxFractionDigits: 4)
                results.append(.answer(expression: query, value: "\(value) \(converted.symbol)"))
            } else if let value = Calculator.evaluate(query) {
                results.append(.answer(expression: query, value: Calculator.format(value)))
            }
        }

        let lower = query.lowercased()
        let ranked = index.apps
            .compactMap { app in app.score(for: lower).map { (app, $0 + recencyBoost(for: app)) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name < $1.0.name }
        results += ranked.prefix(scope == .apps ? 40 : 8).map { .app($0.0) }

        if scope == .all {
            results.append(.web(query))
        }
        return results
    }

    func recordLaunch(of app: AppEntry) {
        recentPaths.removeAll { $0 == app.url.path }
        recentPaths.insert(app.url.path, at: 0)
        recentPaths = Array(recentPaths.prefix(Self.maxRecents))
        UserDefaults.standard.set(recentPaths, forKey: Self.recentsKey)
    }

    func icon(for app: AppEntry) -> NSImage {
        if let cached = icons[app.url] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: app.url.path)
        icons[app.url] = icon
        return icon
    }

    private var recentApps: [AppEntry] {
        recentPaths.compactMap { path in index.apps.first { $0.url.path == path } }
    }

    private func recencyBoost(for app: AppEntry) -> Int {
        guard let rank = recentPaths.firstIndex(of: app.url.path) else { return 0 }
        return 60 - rank * 5
    }
}
