import AppKit
import SwiftUI

/// Title row inside the black surface, below the hardware notch (same slot as the search field).
struct OnboardingHeader: View {
    let state: OnboardingState
    let topInset: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.wave.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            Text("Welcome to Perch")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
            Spacer()
            Text("\(state.index + 1) of \(state.steps.count)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .monospacedDigit()
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

/// Frosted card under the surface: the first-run flow, one step per page.
struct OnboardingCard: View {
    let model: NotchModel
    let state: OnboardingState
    let controller: NotchController

    var body: some View {
        stepPage
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
}

/// The content of one first-run step.
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
            ShortcutRecorderView(slot: .open, shortcut: $settings.hotkey)
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
