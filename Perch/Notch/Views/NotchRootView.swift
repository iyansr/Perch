import SwiftUI

/// Fills the transparent panel. The black surface hangs from the top edge; the results panel drops below it.
/// State changes are animated by the caller (`withAnimation(NotchMotion…)`), so the shape morphs
/// with the right curve for each direction instead of one implicit animation for everything.
struct NotchRootView: View {
    let model: NotchModel
    let controller: NotchController
    /// Follows `model.showsResults`, flipped inside `withAnimation` so typing the first character
    /// drops the panel in (and clearing the query lifts it out) instead of popping.
    @State private var resultsVisible = false

    var body: some View {
        let shape = model.shape
        ZStack(alignment: .top) {
            NotchSurface(model: model, controller: controller)
                .frame(width: shape.size.width, height: shape.size.height)
                .padding(.top, shape.top)

            if model.state == .onboarding, let onboarding = model.onboarding {
                OnboardingCard(model: model, state: onboarding, controller: controller)
                    .padding(.top, model.panelTop)
                    .transition(.commandPanel)
            }

            if model.state == .dropZone, let drop = model.drop, drop.phase == .choosing {
                DropActionPanel(model: model, controller: controller)
                    .padding(.top, model.panelTop)
                    .transition(.commandPanel)
            }

            if model.state == .open, resultsVisible {
                CommandPanelView(model: model, controller: controller)
                    .padding(.top, model.panelTop)
                    .transition(.commandPanel)
            }
        }
        .frame(width: NotchGeometry.windowSize.width, height: NotchGeometry.windowSize.height, alignment: .top)
        .onChange(of: model.showsResults) { _, shows in
            withAnimation(shows ? NotchMotion.panelIn : NotchMotion.panelOut) { resultsVisible = shows }
        }
        // Typing can grow the hit area (results panel) under a cursor that never moves; re-evaluate pass-through.
        .onChange(of: model.interactiveRect) {
            if model.state == .open { controller.updateHover() }
        }
    }
}

private struct NotchSurface: View {
    let model: NotchModel
    let controller: NotchController

    var body: some View {
        let shape = model.shape
        let outline = UnevenRoundedRectangle(
            topLeadingRadius: shape.topRadius,
            bottomLeadingRadius: shape.bottomRadius,
            bottomTrailingRadius: shape.bottomRadius,
            topTrailingRadius: shape.topRadius,
            style: .continuous
        )

        let open = model.state == .open
        let solid = solidFraction(height: shape.size.height)

        // The shape is the base layer, so it renders (and morphs) even when there is no content.
        // While open, frosted glass sits under the gradient: hidden behind the black top, showing through the fade.
        ZStack {
            if open {
                VisualEffectBackground(material: .hudWindow)
                    .transition(.opacity)
            }
            outline.fill(fill(solid: solid))
            content
        }
        .clipShape(outline)
        .overlay {
            if open {
                outline.strokeBorder(rim(solid: solid), lineWidth: 1)
            }
        }
        .background {
            ZStack {
                if open, model.isLoading {
                    LoadingGlow(outline: outline)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.35), value: model.isLoading)
        }
        .contentShape(outline)
        .shadow(color: .black.opacity(model.state == .idle || open ? 0 : 0.4), radius: 22, y: 12)
        .environment(\.colorScheme, .dark)
        .onTapGesture { controller.open() }
        .contextMenu { SurfaceMenu(controller: controller) }
        .keyframeAnimator(
            initialValue: 1.0,
            trigger: PulseTrigger(completion: model.activities.completionTick, hello: model.helloTick)
        ) { view, scale in
            view.scaleEffect(scale, anchor: .top)
        } keyframes: { _ in
            SpringKeyframe(1.08, duration: 0.16)
            SpringKeyframe(1.0, duration: 0.4, spring: .bouncy)
        }
    }

    /// Share of the height that stays solid black: the hardware notch in notch mode, the top 40% for the island.
    private func solidFraction(height: CGFloat) -> CGFloat {
        guard model.geometry.style == .notch else { return 0.4 }
        guard height > 0 else { return 0 }
        return min(model.geometry.notchSize.height / height, 1)
    }

    /// Solid black, except while open: the container fades black → 50% → clear toward its bottom edge.
    /// In notch mode the fade starts below the hardware notch, so the camera housing stays solid black;
    /// on the island it starts 40% down from the top.
    private func fill(solid: CGFloat) -> LinearGradient {
        let open = model.state == .open
        return LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: solid),
                .init(color: .black.opacity(open ? 0.5 : 1), location: solid + (1 - solid) / 2),
                .init(color: .black.opacity(open ? 0 : 1), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Hairline that traces the faded lower edge so the open container still reads as a shape on busy wallpapers.
    private func rim(solid: CGFloat) -> LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .white.opacity(0), location: solid),
                .init(color: .white.opacity(0.28), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .open:
            SearchFieldRow(model: model, topInset: model.geometry.style == .notch ? model.geometry.notchSize.height : 0)
                .transition(.notchContent)
        case .glance where !model.activities.items.isEmpty:
            GlanceCard(model: model)
                .transition(.notchContent)
        case .onboarding:
            if let onboarding = model.onboarding {
                OnboardingHeader(
                    state: onboarding,
                    topInset: model.geometry.style == .notch ? model.geometry.notchSize.height : 0
                )
                .transition(.notchContent)
            }
        case .dropZone:
            if let drop = model.drop {
                let topInset = model.geometry.style == .notch ? model.geometry.notchSize.height : 0
                if drop.phase == .choosing {
                    DropChoosingHeader(drop: drop, topInset: topInset)
                        .transition(.notchContent)
                } else {
                    DropTargetContent(drop: drop, topInset: topInset)
                        .transition(.notchContent)
                }
            }
        case .idle where model.hint != nil:
            OnboardingHint(
                text: model.hint ?? "",
                shortcut: AppSettings.shared.hotkey.displayString,
                topInset: model.geometry.style == .notch ? model.geometry.notchSize.height : 0
            )
            .transition(.notchContent)
        case .idle, .glance:
            IdleActivityContent(model: model)
                .transition(.notchContent)
        }
    }
}

/// Apple Intelligence–style halo that circulates around the container while search work is in flight.
private struct LoadingGlow: View {
    let outline: UnevenRoundedRectangle

    private static let colors: [Color] = [
        Color(red: 0.55, green: 0.62, blue: 1.00), // blue
        Color(red: 0.74, green: 0.51, blue: 0.95), // purple
        Color(red: 0.96, green: 0.56, blue: 0.82), // pink
        Color(red: 1.00, green: 0.70, blue: 0.44), // orange
        Color(red: 0.55, green: 0.62, blue: 1.00), // back to blue so the seam is invisible
    ]
    /// Seconds per lap.
    private static let period: TimeInterval = 2.4

    var body: some View {
        TimelineView(.animation) { context in
            let lap = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period
            let gradient = AngularGradient(colors: Self.colors, center: .center, angle: .degrees(lap * 360))
            ZStack {
                outline.stroke(gradient, lineWidth: 16).blur(radius: 20)
                outline.stroke(gradient, lineWidth: 5).blur(radius: 6)
                outline.stroke(gradient, lineWidth: 2).blur(radius: 1)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct SurfaceMenu: View {
    @Bindable private var settings = AppSettings.shared
    let controller: NotchController

    var body: some View {
        Button("Settings…") { controller.showOnboarding(.settings) }
        Divider()
        Toggle("Play Sounds", isOn: $settings.playsSounds)
        Divider()
        Button("Quit Perch") { NSApp.terminate(nil) }
    }
}

/// Equatable bundle so one keyframe animator pulses for either an activity finishing or the first-run hello.
private struct PulseTrigger: Equatable {
    var completion: Int
    var hello: Int
}

/// Search field that lives inside the black surface, below the hardware notch.
/// Spotlight-style: large query text, the selected result's action trailing it in grey ("tide pools — Open"),
/// and the selected result's icon on the right.
/// NotchController.open() makes it first responder synchronously so the first keystroke lands in it.
private struct SearchFieldRow: View {
    @Bindable var model: NotchModel
    let topInset: CGFloat

    private static let font = Font.system(size: 20, weight: .regular)

    var body: some View {
        // Scope chips can show results for an empty query; the hint and icon wait for typed text,
        // so they never sit on top of the placeholder.
        let hasQuery = !model.query.trimmingCharacters(in: .whitespaces).isEmpty
        let selected = model.showsResults && hasQuery ? model.selectedResult : nil
        HStack(spacing: 12) {
            TextField(
                "Search",
                text: $model.query,
                prompt: Text("Search apps, calculate, or t 25m").foregroundStyle(.white.opacity(0.4))
            )
            .textFieldStyle(.plain)
            .font(Self.font)
            .foregroundStyle(.white)
            .overlay(alignment: .leading) {
                if let selected {
                    // An invisible copy of the query pushes the hint to where the typed text ends.
                    (Text(model.query).foregroundStyle(.clear)
                        + Text(" — \(selected.actionTitle)").foregroundStyle(.white.opacity(0.4)))
                        .font(Self.font)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
            }
            if let selected {
                ResultIcon(result: selected, icon: model.icon(for: selected), size: 30)
                    .id(selected.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: selected?.id)
        .padding(.leading, 24)
        .padding(.trailing, 18)
        .frame(height: NotchModel.openRowHeight)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.top, topInset)
    }
}

struct KeyCap: View {
    let label: String
    var dark = false

    init(_ label: String, dark: Bool = false) {
        self.label = label
        self.dark = dark
    }

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(dark ? Color.white.opacity(0.6) : Color.primary.opacity(0.8))
            .padding(.horizontal, dark ? 7 : 5)
            .padding(.vertical, dark ? 3 : 1)
            .background {
                RoundedRectangle(cornerRadius: dark ? 6 : 5, style: .continuous)
                    .fill(dark ? Color.clear : Color.primary.opacity(0.07))
                    .strokeBorder(dark ? Color.white.opacity(0.18) : Color.clear)
            }
    }
}
