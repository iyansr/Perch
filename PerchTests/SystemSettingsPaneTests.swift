import AppKit
import Testing
@testable import Perch

struct SystemSettingsPaneTests {
    @Test func aliasesFindThePaneHoldingTheSetting() {
        #expect(SystemSettingsPane.matches("wallpaper").first?.pane.title == "Wallpaper")
        #expect(SystemSettingsPane.matches("dock").first?.pane.title == "Desktop & Dock")
        #expect(SystemSettingsPane.matches("dark mode").first?.pane.title == "Appearance")
        #expect(SystemSettingsPane.matches("night shift").first?.pane.title == "Displays")
    }

    @Test func looseSubsequenceHitsAreLeftOut() {
        #expect(SystemSettingsPane.matches("sett").isEmpty)
    }

    /// A wrong identifier still opens System Settings, just on the wrong page, so check each one is installed.
    @Test func everyPaneIdentifierIsAnInstalledSettingsExtension() {
        let installed = SystemSettingsPane.installedBundles()
        for pane in SystemSettingsPane.all {
            #expect(installed[pane.identifier] != nil, "\(pane.title): \(pane.identifier)")
        }
    }

    @Test func everyFallbackSymbolExists() {
        for pane in SystemSettingsPane.all {
            #expect(NSImage(systemSymbolName: pane.symbol, accessibilityDescription: nil) != nil, "\(pane.symbol)")
        }
    }
}
