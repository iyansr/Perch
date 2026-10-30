import Foundation

/// Line diff of two texts for the "review before connecting" view: changed lines with a few lines of context.
nonisolated enum UnifiedDiff {
    struct Line: Equatable, Identifiable, Sendable {
        enum Kind: Sendable { case context, added, removed, gap }
        let id: Int
        let kind: Kind
        let text: String
    }

    static func lines(old: String, new: String, context: Int = 3) -> [Line] {
        let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let difference = newLines.difference(from: oldLines)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }

        var all: [(Line.Kind, String)] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldLines.count || newIndex < newLines.count {
            if removed.contains(oldIndex) {
                all.append((.removed, oldLines[oldIndex]))
                oldIndex += 1
            } else if inserted.contains(newIndex) {
                all.append((.added, newLines[newIndex]))
                newIndex += 1
            } else {
                if oldIndex < oldLines.count { all.append((.context, oldLines[oldIndex])) }
                oldIndex += 1
                newIndex += 1
            }
        }

        let changed = all.indices.filter { all[$0].0 != .context }
        guard !changed.isEmpty else { return [] }
        var keep = Set<Int>()
        for index in changed {
            keep.formUnion(max(0, index - context)...min(all.count - 1, index + context))
        }

        var result: [Line] = []
        var previous: Int?
        for index in keep.sorted() {
            if let previous, index > previous + 1 {
                result.append(Line(id: result.count, kind: .gap, text: "⋯"))
            }
            result.append(Line(id: result.count, kind: all[index].0, text: all[index].1))
            previous = index
        }
        return result
    }
}
