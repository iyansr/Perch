import Testing
import Foundation
@testable import Perch

struct AppSettingsTests {
    private func freshDefaults() -> UserDefaults {
        let name = "perch.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func defaults() {
        let settings = AppSettings(defaults: freshDefaults())
        #expect(settings.hotkey == .default)
        #expect(settings.onboardingDone == false)
        #expect(settings.playsSounds == true)
        #expect(settings.clipboardEnabled == true)
        // Sources that need a permission start off; they prompt when first enabled.
        #expect(settings.enabledSources == ["nowPlaying", "privacy"])
        #expect(settings.replacesSystemHUD == false)
    }

    @Test func persistsOnSet() {
        let defaults = freshDefaults()
        let first = AppSettings(defaults: defaults)
        first.playsSounds = false
        first.onboardingDone = true
        first.hotkey = Shortcut(keyCode: 49, carbonModifiers: 0x100)
        first.enabledSources = ["hud"]

        let second = AppSettings(defaults: defaults)
        #expect(second.playsSounds == false)
        #expect(second.onboardingDone == true)
        #expect(second.hotkey == Shortcut(keyCode: 49, carbonModifiers: 0x100))
        #expect(second.enabledSources == ["hud"]) // turning nowPlaying off sticks
    }
}
