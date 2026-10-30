import AppKit
import SwiftUI

/// Every application, System Settings pane and command the launcher lists, each with a global shortcut
/// and a checkbox that keeps it in (or out of) the launcher.
struct ShortcutsSettingsPage: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case applications = "Applications"
        case settings = "System Settings"
        case commands = "Commands"

        var id: Self { self }

        var searchPrompt: String {
            switch self {
            case .applications: "Search applications…"
            case .settings: "Search System Settings…"
            case .commands: "Search commands…"
            }
        }
    }

    private struct Row: Identifiable {
        let item: LauncherItem
        let title: String
        var id: String { item.key }
    }

    @Bindable private var settings = AppSettings.shared
    private let search = SearchEngine.shared
    @State private var tab: Tab = .applications
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageHeader(section: .shortcuts)
            Picker("Category", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 16)
            searchField
                .padding(.top, 12)
            list
        }
        .onAppear { search.index.refreshIfStale() }
        .onChange(of: tab) { query = "" }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(tab.searchPrompt, text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1))
        }
    }

    private var list: some View {
        let rows = rows
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Show in launcher")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Show in launcher", isOn: showsAll(rows))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .disabled(rows.isEmpty)
                    .help("Show or hide every item listed below")
            }
            .padding(.horizontal, 4)
            LazyVStack(alignment: .leading, spacing: 0) {
                if rows.isEmpty {
                    Text(emptyText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().padding(.leading, 46) }
                    rowView(row)
                }
            }
            .background { shape.fill(Color.primary.opacity(0.04)) }
            .overlay { shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 1) }
        }
        .padding(.top, 16)
    }

    private func rowView(_ row: Row) -> some View {
        HStack(spacing: 12) {
            icon(for: row.item)
                .frame(width: 22, height: 22)
            Text(row.title)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 12)
            ShortcutRecorderView(slot: .launcher(row.item.key), shortcut: $settings.shortcuts[row.item.key])
            Toggle("Show \(row.title) in launcher", isOn: isShown(row.item))
                .toggleStyle(.checkbox)
                .labelsHidden()
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    @ViewBuilder
    private func icon(for item: LauncherItem) -> some View {
        switch item {
        case let .app(url):
            Image(nsImage: search.fileIcon(for: url)).resizable()
        case let .setting(pane):
            if let image = search.icon(for: pane) {
                Image(nsImage: image).resizable()
            } else {
                symbolTile(pane.symbol)
            }
        case let .command(command):
            symbolTile(command.symbol)
        }
    }

    private func symbolTile(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 20)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.08))
            }
    }

    // MARK: Data

    /// The current tab's items A–Z, narrowed to `query`.
    private var rows: [Row] {
        let all: [Row] = switch tab {
        case .applications:
            search.index.apps.map { Row(item: .app($0.url), title: $0.name) } // already A–Z
        case .settings:
            sorted(search.availablePanes.map { Row(item: .setting($0), title: $0.title) })
        case .commands:
            sorted(PerchCommand.allCases.map { Row(item: .command($0), title: $0.title) })
        }
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(needle) }
    }

    private func sorted(_ rows: [Row]) -> [Row] {
        rows.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private var emptyText: String {
        if !query.isEmpty { return "No matches for “\(query)”" }
        return tab == .applications && search.index.isScanning ? "Finding applications…" : "Nothing to show"
    }

    private func isShown(_ item: LauncherItem) -> Binding<Bool> {
        Binding(
            get: { !settings.hiddenInLauncher.contains(item.key) },
            set: { shown in
                if shown { settings.hiddenInLauncher.remove(item.key) } else { settings.hiddenInLauncher.insert(item.key) }
            }
        )
    }

    /// On when every listed row shows; flipping it applies to just the listed rows, so a search narrows it.
    private func showsAll(_ rows: [Row]) -> Binding<Bool> {
        Binding(
            get: { !rows.isEmpty && rows.allSatisfy { !settings.hiddenInLauncher.contains($0.item.key) } },
            set: { shown in
                let keys = Set(rows.map(\.item.key))
                if shown {
                    settings.hiddenInLauncher.subtract(keys)
                } else {
                    settings.hiddenInLauncher.formUnion(keys)
                }
            }
        )
    }
}
