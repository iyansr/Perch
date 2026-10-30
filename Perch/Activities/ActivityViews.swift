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
struct IdleActivityContent: View {
    let model: NotchModel

    var body: some View {
        if let activity = model.activities.sorted.first {
            switch model.geometry.style {
            case .notch:
                HStack(spacing: 0) {
                    ActivityGlyph(activity: activity)
                        .frame(maxWidth: .infinity)
                    Color.clear.frame(width: model.geometry.notchSize.width)
                    ActivityTrailing(activity: activity)
                        .frame(maxWidth: .infinity)
                }
            case .island:
                HStack(spacing: 8) {
                    ActivityGlyph(activity: activity)
                    Text(activity.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                    Spacer(minLength: 0)
                    ActivityTrailing(activity: activity, showsClock: true)
                }
                .padding(.horizontal, 10)
            }
        }
    }
}

/// Hover card: up to three activities with their actions.
struct GlanceCard: View {
    let model: NotchModel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(model.activities.sorted.prefix(NotchModel.glanceMaxRows)) { activity in
                GlanceRow(activity: activity, center: model.activities)
                    .frame(height: NotchModel.glanceRowHeight)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxHeight: .infinity, alignment: .bottom)
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
            ActivityGlyph(activity: activity, size: 15)
                .frame(width: 30, height: 30)
                .background(Circle().fill(activity.status.tint.opacity(0.18)))
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text("\(activity.detail) · \(statusText)")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            ActivityTrailing(activity: activity, showsClock: true)
            actions
        }
    }

    private var statusText: String {
        if case .paused = activity.progress { return "paused" }
        return activity.status.label
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            if activity.status == .running {
                switch activity.progress {
                case .countdown:
                    CircleButton(symbol: "pause.fill") { center.pause(activity.id) }
                case .paused:
                    CircleButton(symbol: "play.fill") { center.resume(activity.id) }
                case .indeterminate, .fraction:
                    EmptyView()
                }
            }
            if case .conversion = activity.kind, !activity.outputs.isEmpty {
                CircleButton(symbol: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting(activity.outputs)
                }
                .help("Reveal in Finder")
            }
            if case .agent = activity.kind, let terminal = activity.terminal {
                CircleButton(symbol: "terminal") { TerminalFocuser.focus(terminal) }
                    .help("Focus terminal")
            }
            CircleButton(symbol: "xmark") { center.dismiss(activity.id) }
        }
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
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(activity.status.tint)
            .symbolEffect(.pulse, isActive: activity.status == .needsAttention)
            .contentTransition(.symbolEffect(.replace))
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
        case let .fraction(value):
            ring(value)
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
