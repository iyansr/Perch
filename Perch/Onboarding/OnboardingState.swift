import ApplicationServices
import AppKit
import Observation

/// How the onboarding card is presented.
enum OnboardingMode: Equatable {
    /// First launch: one step per page, ends with the "Press ⌥Space anytime" hint.
    case firstRun
    /// Pill context menu → Settings…: every step on one page.
    case settings
}

/// One page of the flow. To add a step: add a case here, a title/summary below,
/// and its body in `OnboardingStepBody`. Both modes pick it up from `allCases`.
enum OnboardingStep: CaseIterable, Identifiable {
    case hotkey
    case accessibility
    case agents

    var id: Self { self }

    var title: String {
        switch self {
        case .hotkey: "Open Perch from anywhere"
        case .accessibility: "Allow pasting into other apps"
        case .agents: "Hear from your coding agents"
        }
    }

    var settingsTitle: String {
        switch self {
        case .hotkey: "Shortcut"
        case .accessibility: "Accessibility"
        case .agents: "Agents"
        }
    }
}

enum AccessibilityPermission {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that deep-links to Privacy & Security → Accessibility.
    static func requestPrompt() {
        // `kAXTrustedCheckOptionPrompt`, spelled out because the C global is not concurrency-safe.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

@Observable
final class OnboardingState {
    let mode: OnboardingMode
    let steps = OnboardingStep.allCases
    private(set) var index = 0
    private(set) var isAccessibilityTrusted = AccessibilityPermission.isTrusted
    /// The system prompt only appears once per request; afterwards the button opens System Settings.
    private(set) var didPromptAccessibility = false

    init(mode: OnboardingMode) {
        self.mode = mode
    }

    var step: OnboardingStep { steps[index] }
    var isFirst: Bool { index == 0 }
    var isLast: Bool { index == steps.count - 1 }

    func advance() {
        index = min(index + 1, steps.count - 1)
    }

    func back() {
        index = max(index - 1, 0)
    }

    func refreshAccessibility() {
        let trusted = AccessibilityPermission.isTrusted
        if trusted != isAccessibilityTrusted { isAccessibilityTrusted = trusted }
    }

    func grantAccessibility() {
        if didPromptAccessibility {
            AccessibilityPermission.openSystemSettings()
        } else {
            didPromptAccessibility = true
            AccessibilityPermission.requestPrompt()
        }
    }

    /// Re-checks trust every second while a view showing the permission is on screen.
    func pollAccessibility() async {
        while !Task.isCancelled {
            refreshAccessibility()
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
