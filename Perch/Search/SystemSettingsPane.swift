import Foundation

/// A System Settings pane the launcher can open directly ("wallpaper" → Wallpaper, "dock" → Desktop & Dock).
nonisolated struct SystemSettingsPane: Hashable, Sendable {
    let title: String
    /// Settings extension bundle identifier, as listed in /System/Library/ExtensionKit/Extensions.
    let identifier: String
    let symbol: String
    /// Other words people type for the pane, usually the settings it contains.
    let aliases: [String]

    var url: URL { URL(string: "x-apple.systempreferences:\(identifier)")! }

    /// Panes in System Settings sidebar order.
    static let all: [SystemSettingsPane] = [
        .init("Apple Account", "com.apple.systempreferences.AppleIDSettings", "person.crop.circle",
              ["apple id", "icloud", "sign in"]),
        .init("Family", "com.apple.Family-Settings.extension", "person.3", ["family sharing"]),
        .init("Wi-Fi", "com.apple.wifi-settings-extension", "wifi", ["wifi", "wireless", "internet"]),
        .init("Bluetooth", "com.apple.BluetoothSettings", "antenna.radiowaves.left.and.right",
              ["airpods", "pair device"]),
        .init("Network", "com.apple.Network-Settings.extension", "network",
              ["ethernet", "firewall", "proxy", "dns"]),
        .init("VPN", "com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension", "network.badge.shield.half.filled", []),
        .init("Battery", "com.apple.Battery-Settings.extension", "battery.100",
              ["power", "energy", "low power mode", "charging"]),
        .init("General", "com.apple.systempreferences.GeneralSettings", "gearshape", []),
        .init("About", "com.apple.SystemProfiler.AboutExtension", "info.circle",
              ["about this mac", "serial number", "macos version"]),
        .init("Software Update", "com.apple.Software-Update-Settings.extension", "arrow.triangle.2.circlepath",
              ["update macos", "upgrade"]),
        .init("Storage", "com.apple.settings.Storage", "internaldrive", ["disk space", "free space"]),
        .init("AirDrop & Handoff", "com.apple.AirDrop-Handoff-Settings.extension", "dot.radiowaves.up.forward",
              ["airplay receiver", "continuity"]),
        .init("Login Items", "com.apple.LoginItems-Settings.extension", "list.bullet",
              ["startup apps", "launch at login", "background items", "extensions"]),
        .init("Language & Region", "com.apple.Localization-Settings.extension", "globe",
              ["language", "region", "date format", "translation"]),
        .init("Date & Time", "com.apple.Date-Time-Settings.extension", "clock", ["clock", "time zone"]),
        .init("Sharing", "com.apple.Sharing-Settings.extension", "person.2.badge.gearshape",
              ["file sharing", "screen sharing", "remote login", "computer name"]),
        .init("Time Machine", "com.apple.Time-Machine-Settings.extension", "clock.arrow.circlepath", ["backup"]),
        .init("Transfer or Reset", "com.apple.Transfer-Reset-Settings.extension", "arrow.counterclockwise",
              ["erase", "factory reset", "migration"]),
        .init("Startup Disk", "com.apple.Startup-Disk-Settings.extension", "internaldrive", ["boot"]),
        .init("Accessibility", "com.apple.Accessibility-Settings.extension", "accessibility",
              ["voiceover", "zoom", "reduce motion", "contrast"]),
        .init("Appearance", "com.apple.Appearance-Settings.extension", "circle.lefthalf.filled",
              ["dark mode", "light mode", "accent color", "theme", "scroll bars"]),
        .init("Siri", "com.apple.Siri-Settings.extension", "waveform", ["apple intelligence", "assistant", "hey siri"]),
        .init("Control Center", "com.apple.ControlCenter-Settings.extension", "switch.2", ["menu bar", "status bar"]),
        .init("Desktop & Dock", "com.apple.Desktop-Settings.extension", "dock.rectangle",
              ["dock", "mission control", "stage manager", "hot corners", "default browser", "widgets", "windows"]),
        .init("Displays", "com.apple.Displays-Settings.extension", "display",
              ["monitor", "screen", "resolution", "brightness", "night shift", "true tone"]),
        .init("Spotlight", "com.apple.Spotlight-Settings.extension", "magnifyingglass", []),
        .init("Wallpaper", "com.apple.Wallpaper-Settings.extension", "photo", ["background", "desktop picture"]),
        .init("Notifications", "com.apple.Notifications-Settings.extension", "bell.badge", ["alerts", "banners", "badges"]),
        .init("Sound", "com.apple.Sound-Settings.extension", "speaker.wave.2",
              ["volume", "audio", "output", "input", "microphone", "alert sound"]),
        .init("Focus", "com.apple.Focus-Settings.extension", "moon", ["do not disturb", "dnd"]),
        .init("Screen Time", "com.apple.Screen-Time-Settings.extension", "hourglass",
              ["parental controls", "app limits", "downtime"]),
        .init("Lock Screen", "com.apple.Lock-Screen-Settings.extension", "lock",
              ["screen saver", "sleep", "require password"]),
        .init("Privacy & Security", "com.apple.settings.PrivacySecurity.extension", "hand.raised",
              ["privacy", "security", "permissions", "filevault", "location services", "full disk access"]),
        .init("Touch ID & Password", "com.apple.Touch-ID-Settings.extension", "touchid", ["fingerprint", "login password"]),
        .init("Users & Groups", "com.apple.Users-Groups-Settings.extension", "person.2", ["accounts", "guest user"]),
        .init("Internet Accounts", "com.apple.Internet-Accounts-Settings.extension", "at", ["email accounts", "mail accounts"]),
        .init("Game Center", "com.apple.Game-Center-Settings.extension", "gamecontroller", []),
        .init("Game Controllers", "com.apple.Game-Controller-Settings.extension", "gamecontroller", ["gamepad", "joystick"]),
        .init("Wallet & Apple Pay", "com.apple.WalletSettingsExtension", "wallet.pass", ["apple pay", "cards"]),
        .init("Keyboard", "com.apple.Keyboard-Settings.extension", "keyboard",
              ["key repeat", "keyboard shortcuts", "input sources", "dictation", "text replacement"]),
        .init("Mouse", "com.apple.Mouse-Settings.extension", "computermouse",
              ["tracking speed", "natural scrolling", "scroll direction"]),
        .init("Trackpad", "com.apple.Trackpad-Settings.extension", "rectangle.and.hand.point.up.left",
              ["tap to click", "gestures", "natural scrolling", "scroll direction"]),
        .init("Printers & Scanners", "com.apple.Print-Scan-Settings.extension", "printer", ["printer", "scanner"]),
    ]

    private init(_ title: String, _ identifier: String, _ symbol: String, _ aliases: [String]) {
        self.title = title
        self.identifier = identifier
        self.symbol = symbol
        self.aliases = aliases
    }

    /// Prepared once; matched on every keystroke.
    private static let names: [(SystemSettingsPane, [FuzzyName])] = all.map { pane in
        (pane, ([pane.title] + pane.aliases).map(FuzzyName.init))
    }

    /// Settings extensions on this Mac, by bundle identifier. Their file names vary ("Touch ID & Password.appex",
    /// "DesktopSettings.appex"), so the identifier in each Info.plist is the key. Reads a few hundred plists:
    /// call off the main thread.
    static func installedBundles() -> [String: URL] {
        let root = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions", isDirectory: true)
        let bundles = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var found: [String: URL] = [:]
        for url in bundles {
            let info = url.appending(path: "Contents/Info.plist")
            guard let plist = NSDictionary(contentsOf: info),
                  let identifier = plist["CFBundleIdentifier"] as? String else { continue }
            found[identifier] = url
        }
        return found
    }

    /// Panes matching `query` (lowercased) with their scores, best first. Like commands, loose subsequence hits
    /// are left out: with dozens of panes and aliases, they would bury the panes the user meant.
    static func matches(_ query: String) -> [(pane: SystemSettingsPane, score: Int)] {
        names
            .compactMap { pane, names in
                names.compactMap { $0.score(for: query) }.max().map { (pane: pane, score: $0) }
            }
            .filter { $0.score >= 500 }
            .sorted { $0.score > $1.score }
    }
}
