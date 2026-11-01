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
        } else if case .notification = activity.kind, let image = activity.image {
            ActivityImage(image: image, badge: nil, size: 18)
        } else {
            ActivityGlyph(activity: activity)
        }
    }

    @ViewBuilder
    private func trailing(_ activity: Activity, showsClock: Bool = false) -> some View {
        switch (activity.kind, activity.progress) {
        case (.hud(.capsLock), _), (.weather, _), (.call, _):
            caption(activity.detail) // "On" / "Off"; "18°"; "Muted"
        case (.meeting, _) where activity.presentation == .ambient:
            caption(activity.detail) // start time
        case let (.privacy(sensor), _):
            PrivacyDot(sensor: sensor)
        case (.notification, _):
            EmptyView()
        case (.airdrop, _):
            if let image = activity.image { ActivityImage(image: image, badge: nil, size: 16) }
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

/// Hover card: the decision card while a question waits, the reply card for a message, the music card
/// when music leads, otherwise up to three activities with their actions.
struct GlanceCard: View {
    let model: NotchModel
    let controller: NotchController

    var body: some View {
        let items = model.activities.glanceItems
        if let activity = items.first, let decision = activity.decision {
            DecisionCard(activity: activity, decision: decision)
                .frame(maxHeight: .infinity, alignment: .bottom)
        } else if let activity = items.first, let placeholder = activity.replyPlaceholder {
            ReplyCard(activity: activity, placeholder: placeholder, model: model, controller: controller)
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

/// App or file icon with an optional round badge (AirDrop sender) at its lower right.
struct ActivityImage: View {
    let image: NSImage
    let badge: NSImage?
    let size: CGFloat

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                if let badge {
                    Image(nsImage: badge)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size * 0.5, height: size * 0.5)
                        .clipShape(Circle())
                        .overlay { Circle().strokeBorder(.black, lineWidth: 1.5) }
                        .offset(x: size * 0.12, y: size * 0.12)
                }
            }
    }
}

/// Shared layout for a two-button question (agent permission request, incoming AirDrop): glyph or
/// sender picture, two-line title, optional file icon, full-width Decline / Accept.
/// Stays open on mouse-out until answered (see `NotchController.updateHover`).
struct DecisionCard: View {
    static let height: CGFloat = 116

    let activity: Activity
    let decision: PendingDecision

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                leading
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
                if case .airdrop = activity.kind, let file = activity.image {
                    ActivityImage(image: file, badge: nil, size: 34)
                }
                if !decision.choices.isEmpty {
                    CircleButton(symbol: "xmark") { DecisionRouter.shared.answer(decision, .decline) }
                        .help("Answer in terminal")
                }
            }
            if decision.choices.isEmpty {
                HStack(spacing: 8) {
                    Button(decision.declineTitle) { DecisionRouter.shared.answer(decision, accepted: false) }
                        .buttonStyle(DecisionButtonStyle(fill: .white.opacity(0.14), text: .white))
                    Button(decision.acceptTitle) { DecisionRouter.shared.answer(decision, accepted: true) }
                        // AirDrop's own banner accepts in blue; an agent's Allow stays neutral white.
                        .buttonStyle(decision.owner == "airdrop"
                            ? DecisionButtonStyle(fill: .blue, text: .white)
                            : DecisionButtonStyle(fill: .white, text: .black))
                }
            } else {
                // An agent's question: one button per option, in the agent's order (its pick first).
                HStack(spacing: 8) {
                    ForEach(Array(decision.choices.enumerated()), id: \.offset) { index, choice in
                        Button { DecisionRouter.shared.answer(decision, .choice(choice)) } label: {
                            Text(choice).lineLimit(1).truncationMode(.tail).padding(.horizontal, 6)
                        }
                        .buttonStyle(index == 0
                            ? DecisionButtonStyle(fill: .white, text: .black)
                            : DecisionButtonStyle(fill: .white.opacity(0.14), text: .white))
                        .help(choice)
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(height: Self.height)
    }

    /// AirDrop: the sender's picture (or the AirDrop glyph) rather than the file, which sits on the right.
    @ViewBuilder
    private var leading: some View {
        if case .airdrop = activity.kind, let avatar = activity.badgeImage {
            Image(nsImage: avatar)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 34, height: 34)
                .clipShape(Circle())
        } else {
            ActivityGlyph(activity: activity, size: 16)
                .frame(width: 34, height: 34)
                .background(Circle().fill(activity.status.tint.opacity(0.18)))
        }
    }
}

private struct DecisionButtonStyle: ButtonStyle {
    let fill: Color
    let text: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(text)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(Capsule().fill(fill))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// A message with a reply field. Focusing the field keeps the card open (`NotchModel.isReplying`)
/// and the message on screen; ↵ sends through `ActionRouter.reply`, Esc gives the keyboard back.
struct ReplyCard: View {
    static let height: CGFloat = 128

    let activity: Activity
    let placeholder: String
    let model: NotchModel
    let controller: NotchController
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                if let image = activity.image {
                    ActivityImage(image: image, badge: nil, size: 30)
                } else {
                    ActivityGlyph(activity: activity, size: 15).frame(width: 30, height: 30)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(activity.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(activity.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                ForEach(activity.actions) { action in
                    ActionButton(action: action, activity: activity)
                }
                CircleButton(symbol: "xmark") { finish() }
                    .help("Dismiss")
            }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(.white.opacity(0.1)))
                .focused($focused)
                .onSubmit(send)
                .onExitCommand { finish() }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(height: Self.height)
        .onChange(of: focused) { _, isFocused in
            // Clicking another app or the surface takes the focus without sending: release the card.
            guard isFocused else {
                controller.endReply()
                return
            }
            // Typing takes as long as it takes: the 6 s flash must not pull the message away.
            model.activities.keep(activity.id)
            model.isReplying = true
        }
    }

    private func send() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        ActionRouter.shared.reply(message, to: activity)
        finish()
    }

    private func finish() {
        text = ""
        model.activities.dismiss(activity.id)
        controller.endReply()
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
        } else if let image = activity.image {
            ActivityImage(image: image, badge: activity.badgeImage, size: 30)
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
        case (.meeting, _) where activity.presentation == .ambient, (.weather, _), (.call, _), (.notification, _), (.airdrop, _):
            EmptyView() // the subtitle already says it; buttons follow
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
        case .nowPlaying, .hud, .deviceBattery, .meeting, .privacy, .download, .call, .notification, .weather, .airdrop,
             .dictation:
            activity.detail
        }
    }

    private var statusText: String {
        if case .paused = activity.progress { return "paused" }
        return activity.status.label
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            if let decision = activity.decision, decision.choices.isEmpty {
                CircleButton(symbol: "xmark") { DecisionRouter.shared.answer(decision, accepted: false) }
                    .help(decision.declineTitle)
                CircleButton(symbol: "checkmark") { DecisionRouter.shared.answer(decision, accepted: true) }
                    .help(decision.acceptTitle)
            } else if let decision = activity.decision {
                // A question never gets a bare checkmark: Allow alone answers nothing.
                Menu {
                    ForEach(decision.choices, id: \.self) { choice in
                        Button(choice) { DecisionRouter.shared.answer(decision, .choice(choice)) }
                    }
                    Divider()
                    Button("Answer in Terminal") { DecisionRouter.shared.answer(decision, .decline) }
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(.white.opacity(0.14)))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Answer")
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
            ForEach(activity.actions) { action in
                ActionButton(action: action, activity: activity)
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

    /// Now playing, sensor chips, calls and dictation end with what they track, not on request.
    private var isDismissable: Bool {
        switch activity.kind {
        case .nowPlaying, .privacy, .call, .dictation: false
        default: true
        }
    }
}

/// A source-defined card button (mute, camera, leave, stop). `isOn` lights it; destructive ones are red.
struct ActionButton: View {
    let action: ActivityAction
    let activity: Activity

    var body: some View {
        CircleButton(symbol: action.symbol, fill: fill) { ActionRouter.shared.perform(action, on: activity) }
            .help(action.title)
            .accessibilityLabel(action.title)
    }

    private var fill: Color {
        if action.isDestructive { return .red.opacity(0.85) }
        return action.isOn ? .white.opacity(0.35) : .white.opacity(0.14)
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
    var fill: Color = .white.opacity(0.14)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(fill))
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
        case let .audioLevel(level):
            AudioMeter(level: level, tint: tint, height: 12)
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

/// Four bars that follow a live input level (dictation); the outer bars move less than the middle.
struct AudioMeter: View {
    let level: Double
    var tint: Color = .white
    var height: CGFloat = 14

    private static let weights: [Double] = [0.55, 1, 0.8, 0.45]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Self.weights.indices, id: \.self) { index in
                Capsule()
                    .fill(tint)
                    .frame(width: 2.5, height: height * (0.2 + 0.8 * min(max(level, 0), 1) * Self.weights[index]))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}
