import ApplicationServices
import AppKit
import Observation

/// One page of the first-run flow. To add a step: add a case here, a title below,
/// and its body in `OnboardingStepBody`.
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
}

enum AccessibilityPermission {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that deep-links to Privacy & Security → Accessibility.
    ///
    /// macOS shows that prompt only for an app it has no Accessibility record for. A rebuilt dev copy
    /// (ad-hoc signed, new code signature) keeps its old record, still switched on in System Settings
    /// but no longer matching, so the prompt never appears and the button seems dead. Clearing Perch's
    /// own record first makes the prompt appear and the new copy gets added; we are not trusted here,
    /// so there is no working grant to lose.
    static func requestPrompt() {
        guard !isTrusted else { return }
        if let bundleID = Bundle.main.bundleIdentifier {
            let reset = Process()
            reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            reset.arguments = ["reset", "Accessibility", bundleID]
            reset.standardOutput = FileHandle.nullDevice
            reset.standardError = FileHandle.nullDevice
            try? reset.run()
            reset.waitUntilExit()
        }
        // `kAXTrustedCheckOptionPrompt`, spelled out because the C global is not concurrency-safe.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        // macOS may still skip the prompt (e.g. it already showed this launch); the pane always opens.
        openSystemSettings()
    }

    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

@Observable
final class OnboardingState {
    let steps = OnboardingStep.allCases
    private(set) var index = 0
    private(set) var isAccessibilityTrusted = AccessibilityPermission.isTrusted
    /// The system prompt only appears once per request; afterwards the button opens System Settings.
    private(set) var didPromptAccessibility = false

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
