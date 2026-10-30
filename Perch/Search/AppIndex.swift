import AppKit

nonisolated struct AppEntry: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let match: FuzzyName

    var id: URL { url }

    init(url: URL, name: String) {
        self.url = url
        self.name = name
        match = FuzzyName(name)
    }

    /// Higher is better; nil means no match. `query` must be lowercased.
    func score(for query: String) -> Int? {
        match.score(for: query)
    }
}

/// A name prepared for launcher-style matching: exact, prefix, word prefix, initials, substring, then fuzzy.
nonisolated struct FuzzyName: Hashable, Sendable {
    let lowerName: String
    /// Lowercased words, split on spaces, dashes, dots and camel-case humps ("VS Code" → ["vs", "code"]).
    let words: [String]
    /// First letter of each word ("Visual Studio Code" → "vsc").
    let initials: String

    init(_ name: String) {
        lowerName = name.lowercased()
        words = Self.splitWords(name)
        initials = String(words.compactMap(\.first))
    }

    /// Higher is better; nil means no match. `query` must be lowercased.
    func score(for query: String) -> Int? {
        if lowerName == query { return 1000 }
        if lowerName.hasPrefix(query) { return 900 - min(lowerName.count - query.count, 100) }
        if words.contains(where: { $0.hasPrefix(query) }) { return 750 }
        if query.count > 1, initials.hasPrefix(query) { return 650 }
        if lowerName.contains(query) { return 500 }
        return subsequenceScore(query)
    }

    /// Fuzzy fallback: every query character appears in order; tighter matches score higher.
    private func subsequenceScore(_ query: String) -> Int? {
        var gaps = 0
        var nameIndex = lowerName.startIndex
        for character in query {
            guard let found = lowerName[nameIndex...].firstIndex(of: character) else { return nil }
            gaps += lowerName.distance(from: nameIndex, to: found)
            nameIndex = lowerName.index(after: found)
        }
        return max(1, 300 - gaps * 10)
    }

    private static func splitWords(_ name: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previous: Character?
        for character in name {
            if character == " " || character == "-" || character == "." || character == "_" {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                if character.isUppercase, let previous, previous.isLowercase, !current.isEmpty {
                    words.append(current)
                    current = ""
                }
                current.append(character)
            }
            previous = character
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.lowercased() }
    }
}

/// Installed applications, scanned off the main thread and refreshed when stale.
final class AppIndex {
    private static let staleAfter: TimeInterval = 60

    private(set) var apps: [AppEntry] = []
    var onUpdate: (() -> Void)?

    private var lastScan: Date = .distantPast
    private(set) var isScanning = false

    func refreshIfStale() {
        guard !isScanning, Date().timeIntervalSince(lastScan) > Self.staleAfter else { return }
        isScanning = true
        Task {
            let found = await Task.detached(priority: .userInitiated) { Self.scan() }.value
            apps = found
            lastScan = Date()
            isScanning = false
            onUpdate?()
        }
    }

    nonisolated private static func scan() -> [AppEntry] {
        let fileManager = FileManager.default
        let roots = [
            "/Applications",
            "/System/Applications",
            "/System/Library/CoreServices/Applications",
            NSHomeDirectory() + "/Applications",
        ].map { URL(fileURLWithPath: $0, isDirectory: true) }

        var seen = Set<String>()
        var entries: [AppEntry] = []

        func add(_ url: URL) {
            guard seen.insert(url.resolvingSymlinksInPath().path).inserted else { return }
            var name = fileManager.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name.removeLast(4) }
            entries.append(AppEntry(url: url, name: name))
        }

        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            while let url = enumerator.nextObject() as? URL {
                if url.pathExtension == "app" {
                    add(url)
                } else if enumerator.level >= 3 {
                    enumerator.skipDescendants()
                }
            }
        }
        add(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))

        return entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
