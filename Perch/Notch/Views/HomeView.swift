import AppKit
import SwiftUI

/// What clicking the notch opens: Control Center–style modules inside the black surface.
/// Activity zooms into its detail page; Search and Clipboard hand off to the command panel,
/// and esc there comes back here.
struct HomeView: View {
    let model: NotchModel
    let controller: NotchController

    var body: some View {
        let notch = model.geometry.style == .notch
        // Island: a little more air above the modules, since there is no hardware notch to sit under.
        let top: CGFloat = notch ? 8 : 14
        ZStack(alignment: .top) {
            switch model.homePage {
            case .modules:
                HomeModules(model: model, controller: controller)
                    .homePage(.modules, model: model, top: top)
                    .transition(.homeModules)
            case .activity:
                HomeActivityPage(model: model, controller: controller)
                    .homePage(.activity, model: model, top: top)
                    .transition(.homeDetail)
            }
        }
        .frame(width: NotchGeometry.panelWidth)
        .padding(.top, notch ? model.geometry.notchSize.height : 0)
        .frame(maxHeight: .infinity, alignment: .top)
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
    /// The grid steps back slightly while a detail grows out of its module, and returns the same way.
    static var homeModules: AnyTransition { .opacity.combined(with: .scale(scale: 1.04, anchor: .top)) }
    /// The Activity page grows out of the Activity module (top of the grid) and shrinks back into it.
    static var homeDetail: AnyTransition { .opacity.combined(with: .scale(scale: 0.82, anchor: .top)) }
}

// MARK: - Modules

private struct HomeModules: View {
    let model: NotchModel
    let controller: NotchController

    var body: some View {
        VStack(spacing: 8) {
            ActivityModule(model: model, controller: controller)
            HStack(spacing: 8) {
                if let media = model.activities.items.first(where: { $0.media != nil })?.media {
                    MusicModule(media: media)
                } else {
                    TimerModule(center: model.activities)
                }
                ClipboardModule(controller: controller)
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                SearchModule(controller: controller)
                ConvertModule(center: model.activities)
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button { controller.openSettings() } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(BarButtonStyle())
                .help("Settings")
                .accessibilityLabel("Settings")
                Spacer()
            }
        }
    }
}

/// Up to three activities, most urgent first; click zooms into the full list with actions.
private struct ActivityModule: View {
    let model: NotchModel
    let controller: NotchController
    private static let maxRows = 3

    var body: some View {
        let activities = model.activities.listedItems
        if activities.isEmpty {
            ModuleCard(minHeight: 0) {
                ModuleHeader(title: "Activity")
                Text("Nothing running")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.top, 6)
                HStack(spacing: 4) {
                    Text("Type")
                    KeyCap("t 25m", dark: true)
                    Text("in search to start a timer")
                }
                .moduleNote()
            }
        } else {
            Button { controller.showHomePage(.activity) } label: {
                VStack(alignment: .leading, spacing: 0) {
                    ModuleHeader(title: "Activity", badge: badge(for: activities), showsChevron: true)
                    ForEach(activities.prefix(Self.maxRows)) { activity in
                        CompactActivityRow(activity: activity)
                    }
                    if activities.count > Self.maxRows {
                        Text("+\(activities.count - Self.maxRows) more").moduleNote()
                    }
                }
            }
            .buttonStyle(ModuleButtonStyle(minHeight: 0))
        }
    }

    private func badge(for activities: [Activity]) -> ModuleHeader.Badge? {
        let blocked = activities.filter { $0.status == .needsAttention }.count
        if blocked > 0 { return .init(text: "\(blocked) needs input", tint: .orange) }
        let failed = activities.filter { $0.status == .failed }.count
        if failed > 0 { return .init(text: "\(failed) failed", tint: .red) }
        return nil
    }
}

private struct CompactActivityRow: View {
    let activity: Activity

    var body: some View {
        HStack(spacing: 10) {
            ActivityGlyph(activity: activity, size: 11)
                .frame(width: 22, height: 22)
                .background(Circle().fill(activity.status.tint.opacity(0.18)))
            Text(activity.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text(activity.detail)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
            Spacer(minLength: 8)
            ActivityTrailing(activity: activity, showsClock: true)
        }
        .lineLimit(1)
        .frame(height: 32)
    }
}

/// The running timer as a big clock (click pauses or resumes), otherwise one-click presets.
/// Pomodoro shows its phase and today's completed cycles.
private struct TimerModule: View {
    let center: ActivityCenter
    private static let presets: [TimeInterval] = [5 * 60, 25 * 60]

    var body: some View {
        if let timer = center.sorted.first(where: { $0.kind == .timer && $0.status == .running }) {
            let paused = if case .paused = timer.progress { true } else { false }
            Button {
                if paused { center.resume(timer.id) } else { center.pause(timer.id) }
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    ModuleHeader(title: "\(timer.title) · \(timer.detail)")
                    HStack {
                        clock(timer)
                            .font(.system(size: 28, weight: .semibold).monospacedDigit())
                            .tracking(-0.5) // large display text tightens
                            .foregroundStyle(paused ? .white.opacity(0.6) : .white)
                        Spacer(minLength: 8)
                        ProgressRing(progress: timer.progress, tint: .perchAccent)
                            .frame(width: 24, height: 24)
                    }
                    .padding(.top, 8)
                    Text(paused ? "Paused · click to resume" : "Click to pause").moduleNote()
                }
            }
            .buttonStyle(ModuleButtonStyle())
        } else {
            ModuleCard {
                ModuleHeader(title: "Timer")
                Text("Start a timer")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.top, 8)
                HStack(spacing: 6) {
                    ForEach(Self.presets, id: \.self) { duration in
                        Button(TimerCommand.label(for: duration)) { center.startTimer(.single(duration)) }
                            .buttonStyle(ChipButtonStyle())
                    }
                    Button("Pomodoro") { center.startTimer(.pomodoro) }
                        .buttonStyle(ChipButtonStyle())
                        .help(TimerPlan.pomodoro.label)
                }
                .padding(.top, 10)
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

/// Takes the Timer module's slot while something plays: artwork, track and transport.
private struct MusicModule: View {
    let media: NowPlaying

    var body: some View {
        let source = ActivitySources.shared.nowPlaying
        ModuleCard {
            ModuleHeader(title: "Music")
            HStack(spacing: 10) {
                Button { source.openPlayer() } label: { ArtworkView(image: media.artwork, size: 36) }
                    .buttonStyle(.plain)
                    .help("Open the player")
                VStack(alignment: .leading, spacing: 1) {
                    Text(media.title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(media.artist)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                Waveform(playing: media.isPlaying, height: 12)
            }
            .padding(.top, 8)
            TransportControls(media: media, source: source, playSize: 16, skipSize: 13, spacing: 14)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
        }
    }
}

/// Newest clip; click opens the clipboard panel.
private struct ClipboardModule: View {
    let controller: NotchController

    var body: some View {
        let store = ClipboardStore.shared
        let enabled = AppSettings.shared.clipboardEnabled
        let _ = store.revision // re-read when the history changes
        let item = enabled ? store.newest() : nil
        Button { controller.open(mode: .clipboard) } label: {
            VStack(alignment: .leading, spacing: 0) {
                ModuleHeader(title: "Clipboard", showsChevron: true)
                if let item {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if case let .color(hex) = item.textForm, let color = ClipboardFormat.color(hex: hex) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(color)
                                .frame(width: 10, height: 10)
                        }
                        Text(item.previewText)
                            .font(.system(size: 12))
                            .monospaced(item.kind == .text)
                            .lineLimit(2)
                    }
                    .padding(.top, 8)
                    Text(meta(for: item)).moduleNote()
                } else {
                    Text(enabled ? "Nothing copied yet" : "History is off")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.top, 8)
                    Text(enabled ? "Copies show up here" : "Turn it on in Settings").moduleNote()
                }
            }
        }
        .buttonStyle(ModuleButtonStyle())
    }

    private func meta(for item: ClipboardItem) -> String {
        [ClipboardIcons.shared.appName(bundleID: item.sourceBundleID), ClipboardFormat.relativeTime(from: item.createdAt)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

/// Opens the command panel; typing anywhere in Home does the same.
private struct SearchModule: View {
    let controller: NotchController

    var body: some View {
        Button { controller.open() } label: {
            VStack(alignment: .leading, spacing: 0) {
                ModuleHeader(title: "Search")
                Label("Apps, files, math", systemImage: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.top, 8)
                HStack(spacing: 4) {
                    Text("Start typing, or")
                    KeyCap(AppSettings.shared.hotkey.displayString, dark: true)
                }
                .moduleNote()
            }
        }
        .buttonStyle(ModuleButtonStyle())
    }
}

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

/// Every activity with its actions; esc or "Home" shrinks it back into the Activity module.
private struct HomeActivityPage: View {
    let model: NotchModel
    let controller: NotchController

    var body: some View {
        let activities = model.activities.listedItems
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { controller.showHomePage(.modules) } label: {
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
    struct Badge {
        let text: String
        let tint: Color
    }

    let title: String
    var badge: Badge?
    var showsChevron = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
            if let badge {
                Text(badge.text)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(badge.tint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(badge.tint.opacity(0.18)))
            }
            Spacer(minLength: 0)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(height: 18)
    }
}

/// 18 pt continuous-corner tile; dashed when it is a drop well rather than a control.
private struct ModuleCard<Content: View>: View {
    var dashed = false
    var isHighlighted = false
    var minHeight: CGFloat = 98
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        VStack(alignment: .leading, spacing: 0) { content }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: .infinity, alignment: .topLeading)
            .background { shape.fill(.white.opacity(dashed ? 0 : isHighlighted ? 0.1 : 0.06)) }
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

/// A whole module as one button: lifts on hover, presses in on mouse-down.
private struct ModuleButtonStyle: ButtonStyle {
    var minHeight: CGFloat = 98

    func makeBody(configuration: Configuration) -> some View {
        ModuleButtonBody(configuration: configuration, minHeight: minHeight)
    }

    private struct ModuleButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let minHeight: CGFloat
        @State private var isHovering = false

        var body: some View {
            ModuleCard(isHighlighted: isHovering, minHeight: minHeight) { configuration.label }
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: isHovering)
                .onHover { isHovering = $0 }
        }
    }
}

private struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.2 : 0.1)))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}
