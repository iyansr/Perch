import AppKit
import SwiftUI

/// What clicking the notch opens: a Player-style Home inside the black surface, one page at a time.
/// A floating dock below the surface (see `HomeDock`) switches pages; Activity zooms out of the Home strip.
/// Search is the bar's magnifier or just typing; esc steps back (page → Home → closed).
struct HomeView: View {
    let model: NotchModel
    let controller: NotchController

    var body: some View {
        let notch = model.geometry.style == .notch
        // Notch: the bar sits in the hardware notch's band, pages start below it.
        // Island: no hardware to sit beside, so the bar is its own row at the top.
        let barHeight: CGFloat = notch ? model.geometry.notchSize.height : 32
        let top: CGFloat = notch ? 8 : barHeight + 6
        ZStack(alignment: .top) {
            switch model.homePage {
            case .home:
                HomeLanding(model: model, controller: controller)
                    .homePage(.home, model: model, top: top)
                    .transition(.homeTab)
            case .clipboard:
                ClipboardPage(controller: controller)
                    .homePage(.clipboard, model: model, top: top)
                    .transition(.homeTab)
            case .timer:
                TimerPage(center: model.activities)
                    .homePage(.timer, model: model, top: top)
                    .transition(.homeTab)
            case .convert:
                ConvertModule(center: model.activities)
                    .homePage(.convert, model: model, top: top)
                    .transition(.homeTab)
            case .activity:
                HomeActivityPage(model: model, controller: controller)
                    .homePage(.activity, model: model, top: top)
                    .transition(.homeDetail)
            }
        }
        .frame(width: NotchGeometry.panelWidth)
        .padding(.top, notch ? model.geometry.notchSize.height : 0)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .top) {
            HomeBar(controller: controller)
                .frame(width: NotchGeometry.panelWidth, height: barHeight)
        }
    }
}

private extension View {
    /// Pads a Home page and reports its natural height, which sizes the surface.
    /// Only the current page reports, so a page fading out never holds the surface open.
    func homePage(_ page: HomePage, model: NotchModel, top: CGFloat) -> some View {
        padding(.horizontal, 16)
            .padding(.top, top)
            .padding(.bottom, 16)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { height in
                guard model.homePage == page, abs(model.homeContentHeight - height) > 0.5 else { return }
                withAnimation(NotchMotion.homePage) { model.homeContentHeight = height }
            }
    }

    func moduleNote() -> some View {
        font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.4))
            .lineLimit(1)
            .padding(.top, 6)
    }
}

private extension AnyTransition {
    /// Tabs trade places in place: the surface resizes around them, so only opacity moves.
    static var homeTab: AnyTransition { .opacity }
    /// The Activity page grows out of the Home strip (top of the page) and shrinks back into it.
    static var homeDetail: AnyTransition { .opacity.combined(with: .scale(scale: 0.82, anchor: .top)) }
}

// MARK: - Bar and dock

/// Search on the left, Settings on the right: the only chrome inside the surface.
private struct HomeBar: View {
    let controller: NotchController

    var body: some View {
        HStack {
            Button { controller.open() } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium))
            }
            .help("Search")
            .accessibilityLabel("Search")
            Spacer()
            Button { controller.openSettings() } label: {
                Image(systemName: "gearshape").font(.system(size: 13, weight: .medium))
            }
            .help("Settings")
            .accessibilityLabel("Settings")
        }
        .buttonStyle(BarButtonStyle())
        .padding(.horizontal, 12)
    }
}

enum HomeDockMetrics {
    static let tabSize = CGSize(width: 32, height: 24)
    static let spacing: CGFloat = 1
    static let padding: CGFloat = 3

    /// Used by `NotchModel.interactiveRect` so the mouse reaches the dock.
    static var size: CGSize {
        let count = CGFloat(HomePage.tabs.count)
        return CGSize(
            width: count * tabSize.width + (count - 1) * spacing + 2 * padding,
            height: tabSize.height + 2 * padding
        )
    }
}

/// A separate glass pill under the surface that switches Home pages.
struct HomeDock: View {
    let model: NotchModel
    let controller: NotchController

    var body: some View {
        HStack(spacing: HomeDockMetrics.spacing) {
            ForEach(HomePage.tabs, id: \.self) { page in
                DockTab(page: page, isSelected: model.homePage == page) { controller.showHomePage(page) }
            }
        }
        .padding(HomeDockMetrics.padding)
        .background {
            // Behind-window blur with a dark tint, so the wallpaper shows through but icons keep contrast.
            VisualEffectBackground(material: .hudWindow)
                .overlay { Color.black.opacity(0.25) }
                .clipShape(Capsule())
                .overlay { Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.28), radius: 14, y: 8)
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Home pages")
    }
}

private struct DockTab: View {
    let page: HomePage
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: page.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(isSelected ? 1 : isHovering ? 0.9 : 0.55))
                .frame(width: HomeDockMetrics.tabSize.width, height: HomeDockMetrics.tabSize.height)
                .background { Capsule().fill(.white.opacity(isSelected ? 0.18 : 0)) }
                .contentShape(Capsule())
        }
        .buttonStyle(DockPressStyle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .help(page.title)
        .accessibilityLabel(page.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct DockPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Home

/// Bento dashboard: agents in the tall tile, music and the next meeting beside it,
/// focus, weather and Bluetooth batteries along the bottom. Other activities sit in a strip on top.
private struct HomeLanding: View {
    let model: NotchModel
    let controller: NotchController

    var body: some View {
        let center = model.activities
        let media = center.items.first(where: { $0.media != nil })?.media
        let meeting = center.sorted.first { if case .meeting = $0.kind { true } else { false } }
        let weather = center.items.first { $0.kind == .weather }
        VStack(spacing: 8) {
            ActivityStrip(model: model, controller: controller)
            HStack(alignment: .top, spacing: 8) {
                AgentsTile(center: center, controller: controller)
                    .frame(width: 236)
                VStack(spacing: 8) {
                    if let media { MusicTile(media: media) } else { IdleMusicTile() }
                    MeetingTile(meeting: meeting)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                FocusTile(center: center, controller: controller)
                if let weather { WeatherTile(weather: weather) }
                BatteryTile()
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private func isAgent(_ activity: Activity) -> Bool {
    if case .agent = activity.kind { true } else { false }
}

/// Claude, Codex and `perch watch` sessions, most urgent first; a pending permission request answers inline.
private struct AgentsTile: View {
    let center: ActivityCenter
    let controller: NotchController
    private static let maxRows = 4

    var body: some View {
        let agents = center.sorted.filter(isAgent)
        let asking = agents.first { $0.decision != nil }
        ModuleCard(minHeight: 0) {
            HStack(spacing: 6) {
                ModuleHeader(title: "Agents")
                if let summary = summary(agents) {
                    Text(summary.text)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(summary.tint)
                        .fixedSize()
                }
            }
            if agents.isEmpty {
                Text("No agents running")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.top, 8)
                HStack(spacing: 4) {
                    Text("Run")
                    KeyCap("claude", dark: true)
                    Text("or")
                    KeyCap("perch watch", dark: true)
                }
                .moduleNote()
            } else {
                VStack(spacing: 0) {
                    ForEach(agents.prefix(Self.maxRows)) { agent in AgentRow(agent: agent) }
                }
                .padding(.top, 4)
                .padding(.horizontal, -6)
                if agents.count > Self.maxRows {
                    Button("+\(agents.count - Self.maxRows) more") { controller.showHomePage(.activity) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
                if let asking, let decision = asking.decision {
                    DecisionBox(agent: asking, decision: decision)
                        .padding(.top, 8)
                }
            }
        }
    }

    private func summary(_ agents: [Activity]) -> (text: String, tint: Color)? {
        let waiting = agents.filter { $0.status == .needsAttention }.count
        if waiting > 0 { return ("\(waiting) needs you", .orange) }
        let working = agents.filter { $0.status == .running }.count
        if working > 0 { return ("\(working) working", .perchAccent) }
        return nil
    }
}

/// Glyph, project, "status · age", and a status dot; click brings the agent's terminal forward.
private struct AgentRow: View {
    let agent: Activity
    @State private var isHovering = false

    var body: some View {
        Button {
            if let terminal = agent.terminal { TerminalFocuser.focus(terminal) }
        } label: {
            HStack(spacing: 8) {
                ActivityGlyph(activity: agent, size: 11)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(agent.status.tint.opacity(0.18)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.title)
                        .font(.system(size: 12, weight: .semibold))
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text("\(agent.status.label.capitalized) · \(ClipboardFormat.relativeTime(from: agent.updatedAt, now: context.date))")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 6)
                Circle().fill(agent.status.tint).frame(width: 7, height: 7)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(isHovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(DockPressStyle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .help(agent.terminal == nil ? agent.detail : "Show in terminal")
    }
}

/// The pending permission request: what the agent wants to run, then Deny / Allow.
private struct DecisionBox: View {
    let agent: Activity
    let decision: PendingDecision

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            (Text(agent.title).bold() + Text(" · ") + Text(agent.detail).monospaced())
                .font(.system(size: 11))
                .lineLimit(2)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button(decision.declineTitle) { DecisionRouter.shared.answer(decision, accepted: false) }
                    .buttonStyle(ChipButtonStyle())
                Button(decision.acceptTitle) { DecisionRouter.shared.answer(decision, accepted: true) }
                    .buttonStyle(ChipButtonStyle(fill: .white, text: .black))
            }
        }
        .padding(8)
        .background(shape.fill(Color.orange.opacity(0.12)))
        .overlay(shape.strokeBorder(Color.orange.opacity(0.3), lineWidth: 0.5))
    }
}

/// Artwork, track and waveform, then a slim progress bar and transport.
private struct MusicTile: View {
    let media: NowPlaying

    var body: some View {
        let source = ActivitySources.shared.nowPlaying
        let tint = media.tint.map(Color.init(nsColor:)) ?? .white
        ModuleCard(minHeight: 0) {
            HStack(spacing: 10) {
                Button { source.openPlayer() } label: { ArtworkView(image: media.artwork, size: 40) }
                    .buttonStyle(.plain)
                    .help("Open the player")
                VStack(alignment: .leading, spacing: 1) {
                    Text(media.title).font(.system(size: 12, weight: .semibold))
                    Text(media.artist).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                }
                .lineLimit(1)
                Spacer(minLength: 4)
                Waveform(playing: media.isPlaying, tint: tint, height: 12)
            }
            HStack(spacing: 4) {
                TrackProgress(media: media)
                TransportControls(media: media, source: source, playSize: 13, skipSize: 10, spacing: 0)
            }
            .padding(.top, 8)
        }
    }
}

/// A 4 pt bar that follows the track position; the full scrubber lives in the hover card.
private struct TrackProgress: View {
    let media: NowPlaying

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let duration = media.duration ?? 0
            let fraction = duration > 0 ? min(max(media.position(at: context.date) / duration, 0), 1) : 0
            Capsule().fill(.white.opacity(0.16))
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in Capsule().fill(.white).frame(width: proxy.size.width * fraction) }
                }
                .frame(height: 4)
        }
    }
}

private struct IdleMusicTile: View {
    var body: some View {
        ModuleCard(minHeight: 0) {
            HStack(spacing: 10) {
                Image(systemName: "music.note")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.06)))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Nothing playing").font(.system(size: 12, weight: .semibold))
                    Text("Music or Spotify shows here").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                }
                .lineLimit(1)
            }
        }
    }
}

/// The next calendar event, with Join when it has a meeting link.
private struct MeetingTile: View {
    let meeting: Activity?

    var body: some View {
        ModuleCard(minHeight: 0) {
            HStack(spacing: 5) {
                Image(systemName: "video").font(.system(size: 10, weight: .semibold))
                Text("Next")
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.6))
            .frame(height: 18)
            if let meeting {
                Text(meeting.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .padding(.top, 4)
                HStack(spacing: 6) {
                    Text(meeting.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(meeting.status == .needsAttention ? .orange : .white.opacity(0.4))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let link = meeting.link {
                        Button(link.title) { NSWorkspace.shared.open(link.url) }
                            .buttonStyle(ChipButtonStyle(fill: .green, text: .black))
                    }
                }
                .padding(.top, 6)
            } else {
                Text("Nothing else today")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.top, 4)
                Text("Calendar events show here").moduleNote()
            }
        }
    }
}

/// Ring, clock and play/pause for the running timer; otherwise starts a 25-minute focus.
/// The label opens the Timer page.
private struct FocusTile: View {
    let center: ActivityCenter
    let controller: NotchController

    var body: some View {
        let timer = center.sorted.first { $0.kind == .timer && $0.status == .running }
        let paused = if case .paused = timer?.progress { true } else { false }
        ModuleCard(minHeight: 0) {
            HStack(spacing: 8) {
                Button { controller.showHomePage(.timer) } label: {
                    HStack(spacing: 8) {
                        ProgressRing(progress: timer?.progress ?? .fraction(0), tint: .perchAccent)
                            .frame(width: 26, height: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Group {
                                if let timer { clock(timer) } else { Text("25:00") }
                            }
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            Text(timer?.title ?? "Focus")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Timer")
                Spacer(minLength: 0)
                Button {
                    if let timer {
                        if paused { center.resume(timer.id) } else { center.pause(timer.id) }
                    } else {
                        center.startTimer(.single(25 * 60))
                    }
                } label: {
                    Image(systemName: timer == nil || paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 11))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(BarButtonStyle())
                .accessibilityLabel(timer == nil ? "Start focus" : paused ? "Resume" : "Pause")
            }
        }
    }

    @ViewBuilder
    private func clock(_ timer: Activity) -> some View {
        switch timer.progress {
        case let .countdown(start, end):
            Text(timerInterval: start...end, countsDown: true)
        case let .paused(remaining, _):
            Text(TimerCommand.clock(remaining))
        case .indeterminate, .fraction, .level, .waveform, .audioLevel:
            EmptyView()
        }
    }
}

/// Temperature and place from the weather source; click opens Weather.
private struct WeatherTile: View {
    let weather: Activity

    var body: some View {
        Button {
            if let link = weather.link { NSWorkspace.shared.open(link.url) }
        } label: {
            ModuleCard(minHeight: 0) {
                HStack(spacing: 6) {
                    Image(systemName: weather.symbol)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 13))
                    Text(weather.detail).font(.system(size: 13, weight: .semibold).monospacedDigit())
                }
                .frame(height: 18)
                Text(weather.title)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                    .padding(.top, 3)
            }
        }
        .buttonStyle(.plain)
        .help(weather.link?.title ?? "Weather")
    }
}

/// Connected Bluetooth devices and their charge, refreshed every minute while Home is open.
private struct BatteryTile: View {
    private static let maxRows = 3

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            let devices = ActivitySources.shared.battery.currentBatteries()
            if !devices.isEmpty {
                ModuleCard(minHeight: 0) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(devices.prefix(Self.maxRows)) { device in
                            HStack(spacing: 6) {
                                Image(systemName: device.symbol)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.6))
                                    .frame(width: 14)
                                Text(device.name)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.6))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                let percent = Int(((device.level ?? 0) * 100).rounded())
                                Text("\(percent)%")
                                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                                    .foregroundStyle(percent <= 20 ? .red : .white)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// The most urgent activity that has no tile of its own (download, AirDrop, call, conversion…);
/// more of them open the Activity page.
private struct ActivityStrip: View {
    let model: NotchModel
    let controller: NotchController

    var body: some View {
        let items = model.activities.listedItems.filter { activity in
            if activity.media != nil || isAgent(activity) { return false }
            if case .meeting = activity.kind { return false }
            return true
        }
        if let first = items.first {
            ModuleCard(minHeight: 0) {
                HStack(spacing: 8) {
                    GlanceRow(activity: first, center: model.activities)
                    if items.count > 1 {
                        Button("+\(items.count - 1)") { controller.showHomePage(.activity) }
                            .buttonStyle(ChipButtonStyle())
                            .help("All activity")
                    }
                }
            }
        }
    }
}

// MARK: - Clipboard

/// The latest clips; a click copies the clip back to the pasteboard.
private struct ClipboardPage: View {
    let controller: NotchController
    @State private var copiedID: Int64?
    private static let rows = 4

    var body: some View {
        let store = ClipboardStore.shared
        let enabled = AppSettings.shared.clipboardEnabled
        let _ = store.revision // re-read when the history changes
        let items = enabled ? store.search("", limit: Self.rows) : []
        VStack(spacing: 8) {
            if items.isEmpty {
                ModuleCard(minHeight: 0) {
                    ModuleHeader(title: "Clipboard")
                    Text(enabled ? "Nothing copied yet" : "History is off")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.top, 8)
                    Text(enabled ? "Copies show up here" : "Turn it on in Settings").moduleNote()
                }
            } else {
                VStack(spacing: 2) {
                    ForEach(items) { item in
                        Button { copy(item) } label: { ClipRow(item: item, copied: copiedID == item.id) }
                            .buttonStyle(ClipRowStyle())
                    }
                }
            }
            HStack {
                Spacer()
                Button { controller.open(mode: .clipboard) } label: {
                    HStack(spacing: 4) {
                        Text("Open history")
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    }
                }
                .buttonStyle(ChipButtonStyle())
            }
        }
    }

    private func copy(_ item: ClipboardItem) {
        guard Paster.shared.write(item, plain: false) == .written else { return }
        withAnimation(.easeOut(duration: 0.15)) { copiedID = item.id }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            if copiedID == item.id { withAnimation(.easeOut(duration: 0.15)) { copiedID = nil } }
        }
    }
}

private struct ClipRow: View {
    let item: ClipboardItem
    let copied: Bool

    var body: some View {
        HStack(spacing: 10) {
            glyph
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.previewText)
                    .font(.system(size: 12))
                    .monospaced(item.kind == .text)
                    .lineLimit(1)
                Text(meta)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(copied ? Color.green : .white.opacity(0.4))
                .contentTransition(.symbolEffect(.replace))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var glyph: some View {
        switch item.kind {
        case .image:
            Image(systemName: "photo").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
        case .file:
            Image(systemName: "doc").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
        case .text:
            switch item.textForm {
            case let .color(hex):
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(ClipboardFormat.color(hex: hex) ?? .clear)
                    .frame(width: 12, height: 12)
            case .link:
                Image(systemName: "link").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            case .email:
                Image(systemName: "envelope").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            case .plain:
                Image(systemName: "text.alignleft").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private var meta: String {
        [ClipboardIcons.shared.appName(bundleID: item.sourceBundleID), ClipboardFormat.relativeTime(from: item.createdAt)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

private struct ClipRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ClipRowBody(configuration: configuration)
    }

    private struct ClipRowBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(isHovering ? 0.08 : 0)))
                .scaleEffect(configuration.isPressed ? 0.985 : 1)
                .animation(.easeOut(duration: 0.15), value: isHovering)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .onHover { isHovering = $0 }
        }
    }
}

// MARK: - Timer

/// The running timer as a ring and clock with pause and cancel, otherwise one-click presets.
/// Pomodoro shows its phase and today's completed cycles.
private struct TimerPage: View {
    let center: ActivityCenter
    private static let presets: [TimeInterval] = [5 * 60, 15 * 60, 25 * 60]

    var body: some View {
        if let timer = center.sorted.first(where: { $0.kind == .timer && $0.status == .running }) {
            let paused = if case .paused = timer.progress { true } else { false }
            ModuleCard(minHeight: 0) {
                HStack(spacing: 20) {
                    ZStack {
                        ProgressRing(progress: timer.progress, tint: .perchAccent)
                        clock(timer)
                            .font(.system(size: 22, weight: .semibold).monospacedDigit())
                            .tracking(-0.4)
                            .foregroundStyle(paused ? .white.opacity(0.6) : .white)
                    }
                    .frame(width: 104, height: 104)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(timer.title) · \(timer.detail)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Button {
                                if paused { center.resume(timer.id) } else { center.pause(timer.id) }
                            } label: {
                                Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill")
                            }
                            Button("Cancel") { center.dismiss(timer.id) }
                        }
                        .buttonStyle(ChipButtonStyle())
                        .padding(.top, 10)
                        if let note = pomodoroNote { Text(note).moduleNote() }
                    }
                    Spacer(minLength: 0)
                }
            }
        } else {
            ModuleCard(minHeight: 0) {
                ModuleHeader(title: "Timer")
                Text("Start a timer")
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.top, 8)
                HStack(spacing: 6) {
                    ForEach(Self.presets, id: \.self) { duration in
                        Button(TimerCommand.label(for: duration)) { center.startTimer(.single(duration)) }
                    }
                    Button("Pomodoro") { center.startTimer(.pomodoro) }
                        .help(TimerPlan.pomodoro.label)
                }
                .buttonStyle(ChipButtonStyle())
                .padding(.top, 12)
                if let note = pomodoroNote { Text(note).moduleNote() }
            }
        }
    }

    /// "3 today · 4-day streak"; nil before the first cycle.
    private var pomodoroNote: String? {
        let log = PomodoroLog.shared
        let today = log.cycles()
        let streak = log.streak()
        guard today > 0 || streak > 0 else { return nil }
        let cycles = today == 1 ? "1 Pomodoro today" : "\(today) Pomodoros today"
        return streak > 1 ? "\(cycles) · \(streak)-day streak" : cycles
    }

    @ViewBuilder
    private func clock(_ timer: Activity) -> some View {
        switch timer.progress {
        case let .countdown(start, end):
            Text(timerInterval: start...end, countsDown: true)
        case let .paused(remaining, _):
            Text(TimerCommand.clock(remaining))
        case .indeterminate, .fraction, .level, .waveform, .audioLevel:
            EmptyView()
        }
    }
}

// MARK: - Convert

/// Drop target hint plus the latest conversion; not itself clickable, so it reads as a dashed well.
private struct ConvertModule: View {
    let center: ActivityCenter

    var body: some View {
        ModuleCard(dashed: true) {
            ModuleHeader(title: "Convert")
            if let latest = center.sorted.first(where: { if case .conversion = $0.kind { true } else { false } }) {
                HStack(spacing: 8) {
                    ActivityGlyph(activity: latest, size: 11)
                    Text(latest.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if latest.status != .running, !latest.outputs.isEmpty {
                        CircleButton(symbol: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting(latest.outputs)
                        }
                        .help("Reveal in Finder")
                    }
                }
                .padding(.top, 8)
            } else {
                Text("Drop an image")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.top, 8)
            }
            Label("Drag files onto the notch", systemImage: "arrow.down.doc").moduleNote()
        }
    }
}

// MARK: - Activity page

/// Every activity with its actions; esc or "Home" shrinks it back into the Home strip.
private struct HomeActivityPage: View {
    let model: NotchModel
    let controller: NotchController

    var body: some View {
        let activities = model.activities.listedItems
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { controller.showHomePage(.home) } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("Home")
                    }
                }
                .buttonStyle(BarButtonStyle())
                .padding(.leading, -8)
                Text("Activity")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(activities.count == 1 ? "1 item" : "\(activities.count) items")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .frame(height: 32)
            if activities.isEmpty {
                Text("Nothing running")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                ForEach(activities) { activity in
                    GlanceRow(activity: activity, center: model.activities)
                        .frame(height: NotchModel.glanceRowHeight)
                }
            }
        }
    }
}

// MARK: - Building blocks

private struct ModuleHeader: View {
    var title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.6))
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
    }
}

/// 18 pt continuous-corner tile; dashed when it is a drop well rather than a control.
private struct ModuleCard<Content: View>: View {
    var dashed = false
    var minHeight: CGFloat = 98
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        VStack(alignment: .leading, spacing: 0) { content }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: .infinity, alignment: .topLeading)
            .background { shape.fill(.white.opacity(dashed ? 0 : 0.06)) }
            .overlay {
                if dashed {
                    shape.strokeBorder(.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                } else {
                    shape.strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                }
            }
            .contentShape(shape)
    }
}

/// Capsule button; default is the 10 % control surface, `fill`/`text` make a primary (Allow) or Join chip.
private struct ChipButtonStyle: ButtonStyle {
    var fill: Color?
    var text: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(text)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background {
                if let fill {
                    Capsule().fill(fill).opacity(configuration.isPressed ? 0.8 : 1)
                } else {
                    Capsule().fill(.white.opacity(configuration.isPressed ? 0.2 : 0.1))
                }
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}
