import Carbon.HIToolbox
import Foundation

/// UserDefaults-backed app settings. Every property persists on set.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let hotkey = "perch.hotkey"
        static let onboardingDone = "perch.onboardingDone"
        static let playsSounds = "perch.playsSounds"
        static let clipboardEnabled = "perch.clipboardEnabled"
        static let enabledSources = "perch.enabledSources"
        static let replacesSystemHUD = "perch.replacesSystemHUD"
        static let meetControls = "perch.meetControls"
        static let weatherCity = "perch.weatherCity"
        static let dictationHotkey = "perch.dictationHotkey"
        static let shortcuts = "perch.shortcuts"
        static let hiddenInLauncher = "perch.hiddenInLauncher"
        static let mediaInactivityMinutes = "perch.mediaInactivityMinutes"
    }

    /// Activity sources on for a fresh install: the ones that need no permission.
    static let defaultEnabledSources: Set<String> = ["nowPlaying", "privacy"]

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
    var clipboardEnabled: Bool {
        didSet { defaults.set(clipboardEnabled, forKey: Key.clipboardEnabled) }
    }
    /// `ActivitySource.id`s the user turned on.
    var enabledSources: Set<String> {
        didSet { defaults.set(enabledSources.sorted(), forKey: Key.enabledSources) }
    }
    /// Hide Apple's volume/brightness bezel while Perch's HUD source runs.
    var replacesSystemHUD: Bool {
        didSet { defaults.set(replacesSystemHUD, forKey: Key.replacesSystemHUD) }
    }
    /// Mute/camera/leave for Google Meet in Chrome (needs Chrome's "Allow JavaScript from Apple Events").
    var meetControls: Bool {
        didSet { defaults.set(meetControls, forKey: Key.meetControls) }
    }
    /// City typed in Settings for weather; empty means use the Mac's location.
    var weatherCity: String {
        didSet { defaults.set(weatherCity, forKey: Key.weatherCity) }
    }
    /// Starts and stops dictation.
    var dictationHotkey: Shortcut {
        didSet { defaults.set(try? JSONEncoder().encode(dictationHotkey), forKey: Key.dictationHotkey) }
    }
    /// Global shortcuts for launcher items, by `LauncherItem.key`.
    var shortcuts: [String: Shortcut] {
        didSet { defaults.set(try? JSONEncoder().encode(shortcuts), forKey: Key.shortcuts) }
    }
    /// `LauncherItem.key`s unchecked in Settings › Shortcuts; the launcher leaves them out.
    var hiddenInLauncher: Set<String> {
        didSet { defaults.set(hiddenInLauncher.sorted(), forKey: Key.hiddenInLauncher) }
    }

    /// Hide paused media after this many minutes.
    var mediaInactivityMinutes: Int {
        didSet { defaults.set(mediaInactivityMinutes, forKey: Key.mediaInactivityMinutes) }
    }

    static let defaultDictationHotkey = Shortcut(keyCode: UInt32(kVK_ANSI_D), carbonModifiers: UInt32(controlKey | optionKey))

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hotkey = defaults.data(forKey: Key.hotkey)
            .flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .default
        onboardingDone = defaults.bool(forKey: Key.onboardingDone)
        playsSounds = defaults.object(forKey: Key.playsSounds) as? Bool ?? true
        clipboardEnabled = defaults.object(forKey: Key.clipboardEnabled) as? Bool ?? true
        enabledSources = (defaults.stringArray(forKey: Key.enabledSources)).map(Set.init) ?? Self.defaultEnabledSources
        replacesSystemHUD = defaults.bool(forKey: Key.replacesSystemHUD)
        meetControls = defaults.bool(forKey: Key.meetControls)
        weatherCity = defaults.string(forKey: Key.weatherCity) ?? ""
        dictationHotkey = defaults.data(forKey: Key.dictationHotkey)
            .flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? Self.defaultDictationHotkey
        shortcuts = defaults.data(forKey: Key.shortcuts)
            .flatMap { try? JSONDecoder().decode([String: Shortcut].self, from: $0) } ?? [:]
        hiddenInLauncher = Set(defaults.stringArray(forKey: Key.hiddenInLauncher) ?? [])
        mediaInactivityMinutes = max(1, defaults.object(forKey: Key.mediaInactivityMinutes) as? Int ?? 5)
    }
}
