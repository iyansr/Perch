import AppKit
import SwiftUI

extension Color {
    /// The user's accent colour. `Color.accentColor` renders grey because Perch is never the active app.
    static let perchAccent = Color(nsColor: .controlAccentColor)
}

extension Activity.Status {
    var tint: Color {
        switch self {
        case .running: .perchAccent
        case .needsAttention: .orange
        case .done: .green
        case .failed: .red
        }
    }

    var label: String {
        switch self {
        case .running: "running"
        case .needsAttention: "needs input"
        case .done: "done"
        case .failed: "failed"
        }
    }
}

/// Idle pill content: the top activity in the ears beside the notch, or inline on the island.
/// Music shows artwork and a waveform; HUD and battery flashes show an icon and a level bar.
/// A transient flash slides in over whatever it covers and slides back out.
struct IdleActivityContent: View {
    let model: NotchModel

    var body: some View {
        if let activity = model.activities.sorted.first {
            content(for: activity)
                .id(activity.id)
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .opacity
                ))
        }
    }

    @ViewBuilder
    private func content(for activity: Activity) -> some View {
        switch model.geometry.style {
        case .notch:
            HStack(spacing: 0) {
                leading(activity)
                    .frame(maxWidth: .infinity)
                Color.clear.frame(width: model.geometry.notchSize.width)
                trailing(activity)
                    .frame(maxWidth: .infinity)
            }
        case .island:
            HStack(spacing: 8) {
                leading(activity)
                Text(activity.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if case .level = activity.progress {
                    Text(activity.detail)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                }
                trailing(activity, showsClock: true)
            }
            .padding(.horizontal, 10)
        }
    }

    @ViewBuilder
    private func leading(_ activity: Activity) -> some View {
        if let media = activity.media {
            ArtworkView(image: media.artwork, size: 18)
        } else {
            ActivityGlyph(activity: activity)
        }
    }

    @ViewBuilder
    private func trailing(_ activity: Activity, showsClock: Bool = false) -> some View {
        switch (activity.kind, activity.progress) {
        case (.hud(.capsLock), _):
            caption(activity.detail) // "On" / "Off"
        case (.meeting, _) where activity.presentation == .ambient:
            caption(activity.detail) // start time
        case let (.privacy(sensor), _):
            PrivacyDot(sensor: sensor)
        case let (_, .waveform(playing)):
            Waveform(playing: playing, tint: activity.media?.tint.map(Color.init(nsColor:)) ?? .white, height: 12)
        case let (_, .level(level)):
            // The notch ear is 44 pt; the island has room for a longer bar.
            LevelBar(level: level)
                .frame(width: model.geometry.style == .island ? 64 : 26, height: 4)
        default:
            ActivityTrailing(activity: activity, showsClock: showsClock)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(1)
    }
}

/// macOS's own colours: green for the camera, orange for the microphone.
struct PrivacyDot: View {
    let sensor: Activity.PrivacySensor

    var body: some View {
        Circle()
            .fill(sensor == .camera ? Color.green : Color.orange)
            .frame(width: 7, height: 7)
    }
}

/// Hover card: the decision card while a question waits, the music card when music leads,
/// otherwise up to three activities with their actions.
struct GlanceCard: View {
    let model: NotchModel

    var body: some View {
        let items = model.activities.glanceItems
        if let activity = items.first, let decision = activity.decision {
            DecisionCard(activity: activity, decision: decision)
                .frame(maxHeight: .infinity, alignment: .bottom)
        } else if let media = items.first?.media {
            MusicCard(media: media)
                .frame(maxHeight: .infinity, alignment: .bottom)
        } else {
            VStack(spacing: 0) {
                ForEach(items.prefix(NotchModel.glanceMaxRows)) { activity in
                    GlanceRow(activity: activity, center: model.activities)
                        .frame(height: NotchModel.glanceRowHeight)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

/// Shared layout for a two-button question (agent permission request): glyph, two-line title,
/// full-width Deny / Allow. Stays open on mouse-out until answered (see `NotchController.updateHover`).
struct DecisionCard: View {
    static let height: CGFloat = 116

    let activity: Activity
    let decision: PendingDecision

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ActivityGlyph(activity: activity, size: 16)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(activity.status.tint.opacity(0.18)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(activity.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(activity.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                if let terminal = activity.terminal {
                    CircleButton(symbol: "terminal") { TerminalFocuser.focus(terminal) }
                        .help("Focus terminal")
                }
            }
            HStack(spacing: 8) {
                Button(decision.declineTitle) { DecisionRouter.shared.answer(decision, accepted: false) }
                    .buttonStyle(DecisionButtonStyle(prominent: false))
                Button(decision.acceptTitle) { DecisionRouter.shared.answer(decision, accepted: true) }
                    .buttonStyle(DecisionButtonStyle(prominent: true))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(height: Self.height)
    }
}

private struct DecisionButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(prominent ? .black : .white)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(Capsule().fill(prominent ? Color.white : Color.white.opacity(0.14)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// One activity with its actions; used by the glance card and Home's Activity page.
struct GlanceRow: View {
    let activity: Activity
    let center: ActivityCenter

    var body: some View {
        // An agent row brings its terminal forward (J6); other rows leave the tap to the surface (opens Home).
        if case .agent = activity.kind, let terminal = activity.terminal {
            row
                .contentShape(Rectangle())
                .onTapGesture { TerminalFocuser.focus(terminal) }
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            if activity.batteries.count > 1 {
                OtherBatteries(batteries: Array(activity.batteries.dropFirst()))
            }
            trailing
            actions
        }
    }

    @ViewBuilder
    private var leading: some View {
        if let media = activity.media {
            ArtworkView(image: media.artwork, size: 30)
        } else {
            ActivityGlyph(activity: activity, size: 15)
                .frame(width: 30, height: 30)
                .background(Circle().fill(activity.status.tint.opacity(0.18)))
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch (activity.kind, activity.progress) {
        case let (.privacy(sensor), _):
            PrivacyDot(sensor: sensor)
        case (.meeting, _) where activity.presentation == .ambient:
            EmptyView() // the subtitle already says when
        case let (_, .waveform(playing)):
            Waveform(playing: playing, height: 14)
        case let (_, .level(level)):
            LevelBar(level: level).frame(width: 40, height: 4)
        default:
            ActivityTrailing(activity: activity, showsClock: true)
        }
    }

    /// Status only means something for work that finishes (timers, conversions, agents).
    private var subtitle: String {
        switch activity.kind {
        case .timer, .conversion, .agent: "\(activity.detail) · \(statusText)"
        case .nowPlaying, .hud, .deviceBattery, .meeting, .privacy, .download: activity.detail
        }
    }

    private var statusText: String {
        if case .paused = activity.progress { return "paused" }
        return activity.status.label
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            if let decision = activity.decision {
                CircleButton(symbol: "xmark") { DecisionRouter.shared.answer(decision, accepted: false) }
                    .help(decision.declineTitle)
                CircleButton(symbol: "checkmark") { DecisionRouter.shared.answer(decision, accepted: true) }
                    .help(decision.acceptTitle)
            }
            if activity.status == .running {
                switch activity.progress {
                case .countdown where activity.timerRun != nil:
                    CircleButton(symbol: "pause.fill") { center.pause(activity.id) }
                case .paused:
                    CircleButton(symbol: "play.fill") { center.resume(activity.id) }
                default:
                    EmptyView()
                }
            }
            if let link = activity.link {
                LinkButton(link: link)
            }
            if case let .meeting(eventID) = activity.kind {
                CircleButton(symbol: "calendar") { MeetingSource.showInCalendar(eventID: eventID) }
                    .help("Open in Calendar")
            }
            if !activity.outputs.isEmpty {
                CircleButton(symbol: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting(activity.outputs)
                }
                .help("Reveal in Finder")
            }
            if case .agent = activity.kind, let terminal = activity.terminal {
                CircleButton(symbol: "terminal") { TerminalFocuser.focus(terminal) }
                    .help("Focus terminal")
            }
            if let media = activity.media {
                let source = ActivitySources.shared.nowPlaying
                CircleButton(symbol: media.isPlaying ? "pause.fill" : "play.fill") { source.togglePlayPause() }
                    .help(media.isPlaying ? "Pause" : "Play")
                CircleButton(symbol: "forward.fill") { source.nextTrack() }
                    .help("Next track")
            } else if activity.decision == nil, isDismissable {
                CircleButton(symbol: "xmark") { center.dismiss(activity.id) }
            }
        }
    }

    /// Now playing and sensor chips end with the player or the sensor, not on request.
    private var isDismissable: Bool {
        switch activity.kind {
        case .nowPlaying, .privacy: false
        default: true
        }
    }
}

/// "Join" capsule: the activity's primary link.
private struct LinkButton: View {
    let link: ActivityLink

    var body: some View {
        Button { NSWorkspace.shared.open(link.url) } label: {
            Text(link.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule().fill(.white))
        }
        .buttonStyle(.plain)
        .help(link.url.absoluteString)
    }
}

/// Every other connected device as icon + charge, after the one that just connected.
private struct OtherBatteries: View {
    let batteries: [DeviceBattery]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(batteries.prefix(3)) { device in
                HStack(spacing: 3) {
                    Image(systemName: device.symbol)
                        .font(.system(size: 11))
                    Text(device.level.map { "\(Int(($0 * 100).rounded()))%" } ?? "")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                }
                .foregroundStyle(.white.opacity(0.7))
                .help("\(device.name): \(device.summary)")
            }
        }
    }
}

/// Horizontal 0…1 bar for volume, brightness and battery.
struct LevelBar: View {
    let level: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule().fill(.white).frame(width: proxy.size.width * min(max(level, 0), 1))
            }
        }
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

struct CircleButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }
}

struct ActivityGlyph: View {
    let activity: Activity
    var size: CGFloat = 12

    var body: some View {
        if activity.status == .running, let logo {
            logo
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .foregroundStyle(activity.status.tint)
        } else {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(activity.status.tint)
                .symbolEffect(.pulse, isActive: activity.status == .needsAttention)
                .contentTransition(.symbolEffect(.replace))
        }
    }

    private var logo: Image? {
        guard case let .agent(source, _) = activity.kind else { return nil }
        return source.logo
    }

    private var symbol: String {
        switch activity.status {
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .needsAttention: "exclamationmark.circle.fill"
        case .running: activity.symbol
        }
    }
}

/// Right-hand side of an activity: remaining time and/or progress ring.
struct ActivityTrailing: View {
    let activity: Activity
    var showsClock = false

    var body: some View {
        HStack(spacing: 8) {
            if showsClock { clock }
            ProgressRing(progress: activity.progress, tint: activity.status.tint)
                .frame(width: 14, height: 14)
        }
    }

    @ViewBuilder
    private var clock: some View {
        Group {
            switch activity.progress {
            case let .countdown(start, end) where activity.status == .running:
                Text(timerInterval: start...end, countsDown: true)
            case let .paused(remaining, _):
                Text(TimerCommand.clock(remaining))
            default:
                EmptyView()
            }
        }
        .font(.system(size: 13, weight: .semibold).monospacedDigit())
        .foregroundStyle(.white)
    }
}

struct ProgressRing: View {
    let progress: Activity.Progress
    let tint: Color

    var body: some View {
        switch progress {
        case let .countdown(start, end):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let total = end.timeIntervalSince(start)
                ring(total > 0 ? context.date.timeIntervalSince(start) / total : 1)
            }
        case let .paused(remaining, total):
            ring(total > 0 ? 1 - remaining / total : 1)
        case let .fraction(value), let .level(value):
            ring(value)
        case let .waveform(playing):
            Waveform(playing: playing, tint: tint, height: 12)
        case .indeterminate:
            ProgressView().controlSize(.mini)
        }
    }

    private func ring(_ fraction: Double) -> some View {
        ZStack {
            Circle().stroke(tint.opacity(0.25), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: fraction)
        }
    }
}
