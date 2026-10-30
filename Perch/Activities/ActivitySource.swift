import AppKit
import CoreBluetooth
import AVFoundation
import CoreLocation
import EventKit
import Observation
import SwiftUI

/// A system permission an activity source depends on, and where it stands.
enum SourcePermission: Equatable {
    enum Kind: Equatable {
        case accessibility, bluetooth, calendar, location, microphone, fullDiskAccess

        var title: String {
            switch self {
            case .accessibility: "Accessibility"
            case .bluetooth: "Bluetooth"
            case .calendar: "Calendar"
            case .location: "Location"
            case .microphone: "Microphone"
            case .fullDiskAccess: "Full Disk Access"
            }
        }

        var settingsURL: URL? {
            switch self {
            case .accessibility:
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            case .bluetooth:
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
            case .calendar:
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
            case .location:
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")
            case .microphone:
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            case .fullDiskAccess:
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
            }
        }

        var state: SourcePermission {
            switch self {
            case .accessibility:
                return AccessibilityPermission.isTrusted ? .granted(self) : .needed(self)
            case .bluetooth:
                switch CBManager.authorization {
                case .allowedAlways: return .granted(self)
                case .notDetermined: return .needed(self)
                case .denied, .restricted: return .denied(self)
                @unknown default: return .needed(self)
                }
            case .calendar:
                switch EKEventStore.authorizationStatus(for: .event) {
                case .fullAccess: return .granted(self)
                case .notDetermined: return .needed(self)
                default: return .denied(self) // denied, restricted, or write-only
                }
            case .location:
                switch CLLocationManager().authorizationStatus {
                case .authorizedAlways: return .granted(self)
                case .notDetermined: return .needed(self)
                default: return .denied(self)
                }
            case .microphone:
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized: return .granted(self)
                case .notDetermined: return .needed(self)
                default: return .denied(self)
                }
            case .fullDiskAccess:
                // No API reports it and none prompts for it; reading a protected file is the standard probe.
                return FullDiskAccess.isGranted ? .granted(self) : .needed(self)
            }
        }
    }

    case none
    case needed(Kind)
    case granted(Kind)
    case denied(Kind)
}

enum FullDiskAccess {
    /// The TCC database itself is readable only with Full Disk Access.
    static var isGranted: Bool {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        try? handle.close()
        return true
    }
}

/// Name and look of a source in Settings → Activities.
struct ActivitySourceInfo {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    /// Permission the source needs; sources with one start switched off.
    let permission: SourcePermission.Kind?
}

/// Something outside Perch that feeds the live-activity slot (media, HUD, device battery).
/// Timer, conversion and agent activities are features, not sources: they are always on.
protocol ActivitySource: AnyObject {
    /// Settings key, e.g. "nowPlaying".
    static var id: String { get }
    static var info: ActivitySourceInfo { get }
    func start(center: ActivityCenter)
    func stop()
}

extension ActivitySource {
    var permission: SourcePermission {
        Self.info.permission?.state ?? .none
    }
}

/// Starts and stops every source as `AppSettings.enabledSources` changes.
/// Enabled state lives in `AppSettings`, so views observe that.
final class ActivitySources {
    static let shared = ActivitySources()

    let nowPlaying = NowPlayingSource()
    let hud = HUDSource()
    let battery = BluetoothBatterySource()
    let meeting = MeetingSource()
    let privacy = PrivacySource()
    let downloads = DownloadsSource()
    let call = CallSource()
    let notifications = NotificationSource()
    let weather = WeatherSource()
    let dictation = DictationSource()
    let airdrop = AirDropSource()
    var all: [any ActivitySource] {
        [nowPlaying, hud, battery, meeting, privacy, downloads, call, notifications, weather, dictation, airdrop]
    }
    private var center: ActivityCenter?
    private var running: Set<String> = []
    private let settings = AppSettings.shared

    func start(center: ActivityCenter) {
        self.center = center
        observeSettings()
    }

    func stopAll() {
        for source in all where running.contains(type(of: source).id) {
            source.stop()
        }
        running.removeAll()
    }

    func isEnabled(_ source: any ActivitySource) -> Bool {
        settings.enabledSources.contains(type(of: source).id)
    }

    /// Turning a source on asks for its permission the first time; it runs either way and
    /// picks the permission up once granted. Bluetooth's prompt comes from the source's own
    /// `CBCentralManager` when it starts, so only Accessibility is asked for here.
    func setEnabled(_ source: any ActivitySource, _ enabled: Bool) {
        let id = type(of: source).id
        if enabled {
            if source.permission == .needed(.accessibility) { AccessibilityPermission.requestPrompt() }
            settings.enabledSources.insert(id)
        } else {
            settings.enabledSources.remove(id)
        }
    }

    private func observeSettings() {
        let enabled = withObservationTracking {
            settings.enabledSources
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeSettings() }
        }
        apply(enabled)
    }

    private func apply(_ enabled: Set<String>) {
        guard let center else { return }
        for source in all {
            let id = type(of: source).id
            if enabled.contains(id), !running.contains(id) {
                source.start(center: center)
                running.insert(id)
            } else if !enabled.contains(id), running.contains(id) {
                source.stop()
                running.remove(id)
            }
        }
    }
}
