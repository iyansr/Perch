import AppKit
import SwiftUI

/// Album art with continuous corners; a note glyph when the player sent none.
struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.12))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
    }
}

/// Four bars that bounce while music plays and rest low while paused. Synthetic, not real audio:
/// a real spectrum would need an audio tap and Screen Recording permission.
struct Waveform: View {
    let playing: Bool
    var tint: Color = .white
    var height: CGFloat = 14

    private static let barCount = 4
    private static let tick: TimeInterval = 0.18

    var body: some View {
        if playing {
            TimelineView(.periodic(from: .now, by: Self.tick)) { context in
                bars(at: context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            bars(at: nil)
        }
    }

    private func bars(at time: TimeInterval?) -> some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                Capsule()
                    .fill(tint)
                    .frame(width: 2.5, height: height * fraction(index, time))
            }
        }
        .frame(height: height)
        .animation(.easeInOut(duration: Self.tick), value: time)
    }

    /// Each bar follows its own pair of sines so the motion never visibly repeats.
    private func fraction(_ index: Int, _ time: TimeInterval?) -> CGFloat {
        guard let time else { return 0.25 }
        let i = Double(index)
        let wave = abs(sin(time * (2.1 + i * 0.7) + i * 1.3)) * 0.6 + abs(sin(time * (3.3 - i * 0.4) + i)) * 0.4
        return 0.25 + 0.75 * wave
    }
}

/// `2:35 ━━━━━━ −1:31`: extrapolated locally once a second, draggable to seek.
struct Scrubber: View {
    let media: NowPlaying
    let source: NowPlayingSource
    @State private var dragFraction: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let duration = media.duration ?? 0
            let position = dragFraction.map { $0 * duration } ?? media.position(at: context.date)
            HStack(spacing: 8) {
                Text(TimerCommand.clock(position))
                    .frame(width: 36, alignment: .leading)
                GeometryReader { proxy in
                    let fraction = duration > 0 ? min(max(position / duration, 0), 1) : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.2))
                        Capsule().fill(.white).frame(width: proxy.size.width * fraction)
                    }
                    .frame(height: dragFraction == nil ? 4 : 6)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard duration > 0 else { return }
                                dragFraction = min(max(value.location.x / proxy.size.width, 0), 1)
                            }
                            .onEnded { _ in
                                if let dragFraction, duration > 0 { source.seek(to: dragFraction * duration) }
                                dragFraction = nil
                            }
                    )
                }
                .frame(height: 14)
                Text("−" + TimerCommand.clock(max(0, duration - position)))
                    .frame(width: 40, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.6))
            .animation(.easeOut(duration: 0.12), value: dragFraction == nil)
        }
    }
}

/// ⏮ ⏯ ⏭ for the system's now-playing app.
struct TransportControls: View {
    let media: NowPlaying
    let source: NowPlayingSource
    var playSize: CGFloat = 28
    var skipSize: CGFloat = 22
    var spacing: CGFloat = 28

    var body: some View {
        HStack(spacing: spacing) {
            button("backward.fill", size: skipSize, label: "Previous track") { source.previousTrack() }
            button(media.isPlaying ? "pause.fill" : "play.fill", size: playSize, label: media.isPlaying ? "Pause" : "Play") {
                source.togglePlayPause()
            }
            .contentTransition(.symbolEffect(.replace))
            button("forward.fill", size: skipSize, label: "Next track") { source.nextTrack() }
        }
        .foregroundStyle(.white)
    }

    private func button(_ symbol: String, size: CGFloat, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: size + 14, height: size + 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct PressScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The glance card when music is the top activity: artwork, track, waveform, scrubber and transport.
struct MusicCard: View {
    static let height: CGFloat = 150

    let media: NowPlaying

    var body: some View {
        let source = ActivitySources.shared.nowPlaying
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                Button { source.openPlayer() } label: { ArtworkView(image: media.artwork, size: 56) }
                    .buttonStyle(.plain)
                    .help("Open the player")
                VStack(alignment: .leading, spacing: 2) {
                    Text(media.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(media.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
                Waveform(playing: media.isPlaying, tint: tint ?? .white, height: 16)
                    .padding(.top, 8)
            }
            Scrubber(media: media, source: source)
            TransportControls(media: media, source: source)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(height: Self.height)
        .background { (tint ?? .clear).opacity(0.12) }
    }

    private var tint: Color? {
        media.tint.map(Color.init(nsColor:))
    }
}
