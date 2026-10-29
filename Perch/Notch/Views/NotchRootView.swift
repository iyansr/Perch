import SwiftUI

/// Fills the transparent panel. The black surface hangs from the top edge; the results panel drops below it.
/// State changes are animated by the caller (`withAnimation(NotchMotion…)`), so the shape morphs
/// with the right curve for each direction instead of one implicit animation for everything.
struct NotchRootView: View {
    let model: NotchModel
    let controller: NotchController

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

            if model.state == .open {
                CommandPanelView(model: model, controller: controller)
                    .padding(.top, model.panelTop)
                    .transition(.commandPanel)
            }
        }
        .frame(width: NotchGeometry.windowSize.width, height: NotchGeometry.windowSize.height, alignment: .top)
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

        // The black shape is the base layer, so it renders (and morphs) even when there is no content.
        ZStack {
            outline.fill(.black)
            content
        }
        .clipShape(outline)
        .contentShape(outline)
        .shadow(color: .black.opacity(model.state == .idle ? 0 : 0.4), radius: 22, y: 12)
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
/// NotchController.open() makes it first responder synchronously so the first keystroke lands in it.
private struct SearchFieldRow: View {
    @Bindable var model: NotchModel
    let topInset: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            TextField(
                "Search",
                text: $model.query,
                prompt: Text("Search apps, calculate, or t 25m").foregroundStyle(.white.opacity(0.5))
            )
            .textFieldStyle(.plain)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.white)
            KeyCap("esc", dark: true)
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: NotchModel.searchRowHeight)
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
