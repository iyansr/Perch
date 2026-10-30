import AppKit
import SwiftUI

/// Title row inside the black surface, below the hardware notch (same slot as the search field).
struct OnboardingHeader: View {
    let state: OnboardingState
    let topInset: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.mode == .firstRun ? "hand.wave.fill" : "gearshape.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            Text(state.mode == .firstRun ? "Welcome to Perch" : "Settings")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
            Spacer()
            if state.mode == .firstRun {
                Text("\(state.index + 1) of \(state.steps.count)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .monospacedDigit()
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .frame(height: NotchModel.searchRowHeight)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.top, topInset)
    }
}

/// Pill message shown in the collapsed surface for a moment: "Press ⌥Space anytime" after the first run,
/// or any other short text (e.g. "Copied — enable paste in Settings").
struct OnboardingHint: View {
    let text: String
    let shortcut: String
    let topInset: CGFloat

    var body: some View {
        Group {
            if text == "Press \(shortcut) anytime" {
                HStack(spacing: 8) {
                    Text("Press")
                    KeyCap(shortcut, dark: true)
                    Text("anytime")
                }
            } else {
                Text(text)
                    .lineLimit(1)
                    .padding(.horizontal, 16)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white.opacity(0.85))
        .frame(maxWidth: .infinity)
        .frame(height: NotchModel.searchRowHeight)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.top, topInset)
        .accessibilityLabel(text)
    }
}

/// Frosted card under the surface. First run steps through `state.steps`; settings shows all of them at once.
struct OnboardingCard: View {
    let model: NotchModel
    let state: OnboardingState
    let controller: NotchController
    @FocusState private var pageFocused: Bool
    @State private var settingsHeight: CGFloat = 0

    /// Room left in the window under the surface: card padding (36), the Done row (54) and a margin.
    private var settingsMaxHeight: CGFloat {
        max(200, NotchGeometry.windowSize.height - model.panelTop - 36 - 54 - 24)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch state.mode {
            case .firstRun: stepPage
            case .settings: settingsPage
            }
        }
        .padding(18)
        .frame(width: NotchGeometry.panelWidth)
        .background {
            VisualEffectBackground()
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.35))
        }
        .shadow(color: .black.opacity(0.3), radius: 30, y: 20)
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { model.panelHeight = $0 }
    }

    // MARK: First run

    private var stepPage: some View {
        let step = state.step
        return VStack(alignment: .leading, spacing: 14) {
            Text(step.title)
                .font(.system(size: 17, weight: .semibold))
            OnboardingStepBody(step: step, state: state)
                .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
                .id(step)
                .transition(.opacity)
            HStack {
                if !state.isFirst {
                    Button("Back") { withAnimation(.smooth(duration: 0.25)) { state.back() } }
                }
                Spacer()
                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
    }

    /// Accessibility is optional: without it Perch keeps working in copy-only mode.
    private var skipsPermission: Bool {
        state.step == .accessibility && !state.isAccessibilityTrusted
    }

    private var primaryTitle: String {
        if skipsPermission { return "Skip" }
        return state.isLast ? "Done" : "Continue"
    }

    private func primaryAction() {
        if state.isLast {
            controller.finishOnboarding()
        } else {
            withAnimation(.smooth(duration: 0.25)) { state.advance() }
        }
    }

    // MARK: Settings

    @ViewBuilder
    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Scrolls once the sections outgrow the window (e.g. while a hook diff is open).
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(state.steps.enumerated()), id: \.element) { index, step in
                        if index > 0 { Divider().padding(.vertical, 12) }
                        Text(step.settingsTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 8)
                        OnboardingStepBody(step: step, state: state)
                    }
                    Divider().padding(.vertical, 12)
                    SoundsToggle()
                }
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { settingsHeight = $0 }
            }
            .scrollIndicators(.automatic)
            .frame(height: min(settingsHeight, settingsMaxHeight))
            HStack {
                Spacer()
                Button("Done") { controller.finishOnboarding() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(.top, 14)
        }
        // Esc closes the page. The recorder's key monitor swallows Esc while recording, so it never reaches here then.
        .focusable()
        .focusEffectDisabled()
        .focused($pageFocused)
        .onAppear { pageFocused = true }
        .onKeyPress(.escape) {
            controller.finishOnboarding()
            return .handled
        }
    }
}

private struct SoundsToggle: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Toggle("Play sounds", isOn: $settings.playsSounds)
            .toggleStyle(.switch)
            .font(.system(size: 13))
    }
}

/// The content of one step. Shared by the stepped first-run flow and the single settings page.
private struct OnboardingStepBody: View {
    let step: OnboardingStep
    let state: OnboardingState

    var body: some View {
        switch step {
        case .hotkey: HotkeyStepBody()
        case .accessibility: AccessibilityStepBody(state: state)
        case .agents: AgentsStepBody()
        }
    }
}

private struct HotkeyStepBody: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Press \(settings.hotkey.displayString) in any app to summon Perch. Click the shortcut to record a different one.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ShortcutRecorderView(shortcut: $settings.hotkey)
        }
    }
}

private struct AccessibilityStepBody: View {
    let state: OnboardingState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Perch needs Accessibility access to paste into the app you were using. Without it, items are copied to the clipboard and you paste them yourself.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if state.isAccessibilityTrusted {
                Label("Accessibility is on", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.green)
            } else {
                Button(state.didPromptAccessibility ? "Open System Settings…" : "Grant Access…") {
                    state.grantAccessibility()
                }
            }
        }
        .task { await state.pollAccessibility() }
    }
}
