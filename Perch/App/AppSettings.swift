import Foundation

/// UserDefaults-backed app settings. Every property persists on set.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let hotkey = "perch.hotkey"
        static let onboardingDone = "perch.onboardingDone"
        static let playsSounds = "perch.playsSounds"
        static let aiProvider = "perch.aiProvider"
        static let clipboardEnabled = "perch.clipboardEnabled"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var hotkey: Shortcut {
        didSet { defaults.set(try? JSONEncoder().encode(hotkey), forKey: Key.hotkey) }
    }
    var onboardingDone: Bool {
        didSet { defaults.set(onboardingDone, forKey: Key.onboardingDone) }
    }
    var playsSounds: Bool {
        didSet { defaults.set(playsSounds, forKey: Key.playsSounds) }
    }
    var aiProvider: String {
        didSet { defaults.set(aiProvider, forKey: Key.aiProvider) }
    }
    var clipboardEnabled: Bool {
        didSet { defaults.set(clipboardEnabled, forKey: Key.clipboardEnabled) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hotkey = defaults.data(forKey: Key.hotkey)
            .flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .default
        onboardingDone = defaults.bool(forKey: Key.onboardingDone)
        playsSounds = defaults.object(forKey: Key.playsSounds) as? Bool ?? true
        aiProvider = defaults.string(forKey: Key.aiProvider) ?? "anthropic"
        clipboardEnabled = defaults.object(forKey: Key.clipboardEnabled) as? Bool ?? true
    }
}
