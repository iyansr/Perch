import AppKit

/// What the search field searches. `.root` is the single launcher list (apps, commands, answers);
/// commands such as Clipboard History push the other modes.
enum SearchMode: Equatable {
    case root, clipboard, files

    /// Tag shown in front of the search field while a command is open.
    var title: String? {
        switch self {
        case .root: nil
        case .clipboard: PerchCommand.clipboardHistory.title
        case .files: PerchCommand.searchFiles.title
        }
    }

    var placeholder: String {
        switch self {
        case .root: "Search for apps, settings and commands…"
        case .clipboard: "Search clipboard history…"
        case .files: "Search files…"
        }
    }
}

/// Built-in commands, listed under "Commands" in the root list.
enum PerchCommand: CaseIterable {
    case clipboardHistory, searchFiles, settings, quit

    var title: String {
        switch self {
        case .clipboardHistory: "Clipboard History"
        case .searchFiles: "Search Files"
        case .settings: "Settings"
        case .quit: "Quit Perch"
        }
    }

    var symbol: String {
        switch self {
        case .clipboardHistory: "doc.on.clipboard"
        case .searchFiles: "doc.text.magnifyingglass"
        case .settings: "gearshape"
        case .quit: "power"
        }
    }

    /// Other words people type for the command; matched like the title.
    private var aliases: [String] {
        switch self {
        case .clipboardHistory: ["clip", "paste", "copy history"]
        case .searchFiles: ["find files", "open file", "documents"]
        case .settings: ["preferences", "hotkey", "shortcut"]
        case .quit: ["exit", "close perch"]
        }
    }

    /// Prepared once; matched on every keystroke.
    private static let names: [(PerchCommand, [FuzzyName])] = allCases.map { command in
        (command, ([command.title] + command.aliases).map(FuzzyName.init))
    }

    /// Commands matching `query` (lowercased), best first. Loose subsequence hits are left out, so a short
    /// query that happens to spell across "Quit Perch" never puts it under the cursor.
    static func matches(_ query: String) -> [PerchCommand] {
        names
            .compactMap { command, names in
                names.compactMap { $0.score(for: query) }.max().map { (command, $0) }
            }
            .filter { $0.1 >= 500 }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
}

/// Header a run of rows sits under in the results list.
enum ResultSection: String {
    case results = "Results"
    case recent = "Recent"
    case applications = "Applications"
    case settings = "System Settings"
    case commands = "Commands"
    /// Fallback rows that hand the query to another search: the web, or Search Files.
    case search = "Search"
    case files = "Files"
    case clipboard = "Clipboard"
}

enum SearchResult: Identifiable, Equatable {
    /// `isRecent` puts the row under "Recent" in the empty-query list.
    case app(AppEntry, isRecent: Bool = false)
    /// Inline math or unit answer; ↵ copies `value`.
    case answer(expression: String, value: String)
    case timer(TimerPlan)
    case web(String)
    /// ↵ opens, ⌘↵ reveals in Finder.
    case file(URL)
    /// System Settings pane; ↵ opens it.
    case setting(SystemSettingsPane)
    /// Fallback row; ↵ opens Search Files with the query.
    case fileSearch(String)
    /// Clipboard history row; ↵ pastes, ⌘↵ copies.
    case clip(ClipboardItem)
    case command(PerchCommand)

    var id: String {
        switch self {
        case let .app(app, _): "app:\(app.url.path)"
        case let .answer(expression, _): "answer:\(expression)"
        case let .timer(plan): "timer:\(plan.label)"
        case let .web(query): "web:\(query)"
        case let .file(url): "file:\(url.path)"
        case let .setting(pane): "setting:\(pane.identifier)"
        case let .fileSearch(query): "filesearch:\(query)"
        case let .clip(item): "clip:\(item.id)"
        case let .command(command): "command:\(command)"
        }
    }

    var title: String {
        switch self {
        case let .app(app, _): app.name
        case let .answer(expression, value): "\(expression) = \(value)"
        case let .timer(plan): plan.isPomodoro ? "Start \(plan.label)" : "Start \(plan.label) timer"
        case let .web(query): "Search the web for “\(query)”"
        case let .file(url): url.lastPathComponent
        case let .setting(pane): pane.title
        case let .fileSearch(query): "Search files for “\(query)”"
        case let .clip(item): item.previewText
        case let .command(command): command.title
        }
    }

    /// Right-aligned type label, like Spotlight/Raycast ("Application", "Command").
    var kind: String {
        switch self {
        case .app: "Application"
        case .answer: "Copy Result"
        case .timer: "Command"
        case .web: "Web Search"
        case .file: "File"
        case .setting: "System Settings"
        case .fileSearch: "File Search"
        case .clip(let item): item.kindLabel
        case .command: "Command"
        }
    }

    var section: ResultSection {
        switch self {
        case .answer, .timer: .results
        case let .app(_, isRecent): isRecent ? .recent : .applications
        case .command: .commands
        case .web, .fileSearch: .search
        case .file: .files
        case .setting: .settings
        case .clip: .clipboard
        }
    }

    /// What ↵ does, shown inline after the query ("tide pools — Open").
    var actionTitle: String {
        switch self {
        case .app, .file, .setting: "Open"
        case .answer: "Copy"
        case .timer: "Start Timer"
        case .web: "Search Web"
        case .fileSearch: "Search Files"
        case .clip: "Paste"
        case .command(.quit): "Quit"
        case .command: "Open Command"
        }
    }
}

final class SearchEngine {
    private static let recentsKey = "perch.recentApps"
    private static let maxRecents = 8

    let index = AppIndex()
    let files = FileSearch()
    private var icons: [URL: NSImage] = [:]
    private var recentPaths: [String]
    /// Installed settings extensions by bundle identifier; empty until the first scan lands.
    private var settingsBundles: [String: URL] = [:]

    init() {
        recentPaths = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
        index.refreshIfStale()
        Task {
            settingsBundles = await Task.detached(priority: .utility) { SystemSettingsPane.installedBundles() }.value
        }
    }

    /// Work the user is waiting on: a Spotlight file query, or the first app scan (later rescans keep old results).
    var isBusy: Bool {
        files.isSearching || (index.isScanning && index.apps.isEmpty)
    }

    /// Root results are grouped by `SearchResult.section`, in the order the list shows them:
    /// answers, applications, System Settings panes, commands, then the web and file-search fallbacks. Settings
    /// move above applications when their best match is stronger, so "wallpaper" opens the pane, not a fuzzy app hit.
    /// An empty query lists recent apps and every command.
    func results(for rawQuery: String, mode: SearchMode) -> [SearchResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode == .files {
            files.update(query: query)
            return files.results.map(SearchResult.file)
        }
        files.cancel()
        if mode == .clipboard {
            return ClipboardStore.shared.search(query, filter: ClipboardPanelState.shared.filter).map(SearchResult.clip)
        }
        guard !query.isEmpty else {
            // Recent apps, then every other app A–Z (the index is sorted), then every command.
            let recents = recentPaths.compactMap { path in index.apps.first { $0.url.path == path } }
            let recentURLs = Set(recents.map(\.url))
            return recents.map { .app($0, isRecent: true) }
                + index.apps.filter { !recentURLs.contains($0.url) }.map { .app($0) }
                + PerchCommand.allCases.map(SearchResult.command)
        }

        var results: [SearchResult] = []
        if let plan = TimerCommand.parse(query) {
            results.append(.timer(plan))
        }
        if let converted = UnitConverter.convert(query) {
            let value = Calculator.format(converted.value, maxFractionDigits: 4)
            results.append(.answer(expression: query, value: "\(value) \(converted.symbol)"))
        } else if let value = Calculator.evaluate(query) {
            results.append(.answer(expression: query, value: Calculator.format(value)))
        }

        let lower = query.lowercased()
        let ranked = index.apps
            .compactMap { app in app.score(for: lower).map { (app, $0 + recencyBoost(for: app)) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name < $1.0.name }
        let apps = ranked.prefix(8).map { SearchResult.app($0.0) }
        // Panes missing on this macOS version are dropped once the extension scan has landed.
        let settings = SystemSettingsPane.matches(lower)
            .filter { settingsBundles.isEmpty || settingsBundles[$0.pane.identifier] != nil }
            .prefix(5)
        let panes = settings.map { SearchResult.setting($0.pane) }
        if let topSetting = settings.first?.score, topSetting > ranked.first?.1 ?? 0 {
            results += panes + apps
        } else {
            results += apps + panes
        }
        results += PerchCommand.matches(lower).map(SearchResult.command)
        results.append(.web(query))
        results.append(.fileSearch(query))
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

    func fileIcon(for url: URL) -> NSImage {
        if let cached = icons[url] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[url] = icon
        return icon
    }

    /// The pane's own System Settings icon, or nil (symbol tile) when its extension wasn't found.
    func icon(for pane: SystemSettingsPane) -> NSImage? {
        guard let url = settingsBundles[pane.identifier] else { return nil }
        return fileIcon(for: url)
    }

    private func recencyBoost(for app: AppEntry) -> Int {
        guard let rank = recentPaths.firstIndex(of: app.url.path) else { return 0 }
        return 60 - rank * 5
    }
}
