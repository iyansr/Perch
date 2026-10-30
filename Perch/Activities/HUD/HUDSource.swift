import AppKit
import AudioToolbox
import CoreAudio
import Observation
import SwiftUI

/// Volume, brightness and keyboard-backlight bars as 1.5 s flashes in the pill, plus a 1 s Caps Lock chip.
/// Volume comes from a CoreAudio listener, so it catches every change (keys, menu bar, apps) without
/// a permission. Brightness and backlight have no change notification that excludes auto-brightness,
/// so they follow the keys through `MediaKeyTap` (NSEvent monitors, Accessibility); Caps Lock shares it.
final class HUDSource: ActivitySource {
    static let id = "hud"
    static let info = ActivitySourceInfo(
        title: "Volume, Brightness & Caps Lock",
        detail: "A level bar in the pill when you change volume, display brightness or keyboard backlight, and a chip when Caps Lock toggles.",
        symbol: "speaker.wave.2.fill",
        tint: .blue,
        permission: .accessibility
    )

    static let duration: Duration = .milliseconds(1500)
    static let capsLockDuration: Duration = .seconds(1)

    private weak var center: ActivityCenter?
    private var device: AudioObjectID?
    private var levelListener: AudioObjectPropertyListenerBlock?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private lazy var keyTap = MediaKeyTap { [weak self] key in self?.keyPressed(key) }
    /// Retries the key tap until Accessibility is granted.
    private var tapRetry: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var isSuppressing = false
    private var isRunning = false

    func start(center: ActivityCenter) {
        self.center = center
        isRunning = true
        watchDefaultDevice()
        attachVolumeListener()
        startKeyTap()
        observeReplaceSetting()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isSuppressing else { return }
                SystemHUDSuppressor.suppress()
            }
        }
    }

    func stop() {
        isRunning = false
        detachVolumeListener()
        if let deviceListener {
            var address = Self.defaultDeviceAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, deviceListener)
        }
        deviceListener = nil
        keyTap.stop()
        tapRetry?.invalidate()
        tapRetry = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        setSuppressing(false)
    }

    // MARK: Volume

    private static let defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// Headphones plugged in or AirPods connected: follow the new default output.
    private func watchDefaultDevice() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.detachVolumeListener()
                self?.attachVolumeListener()
            }
        }
        var address = Self.defaultDeviceAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        deviceListener = listener
    }

    private func attachVolumeListener() {
        guard let device = SystemLevels.defaultOutputDevice() else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.showVolume() }
        }
        for var address in [SystemLevels.volumeAddress, SystemLevels.muteAddress] {
            guard AudioObjectHasProperty(device, &address) else { continue }
            AudioObjectAddPropertyListenerBlock(device, &address, .main, listener)
        }
        self.device = device
        levelListener = listener
    }

    private func detachVolumeListener() {
        guard let device, let levelListener else { return }
        for var address in [SystemLevels.volumeAddress, SystemLevels.muteAddress] {
            AudioObjectRemovePropertyListenerBlock(device, &address, .main, levelListener)
        }
        self.device = nil
        self.levelListener = nil
    }

    private func showVolume() {
        guard let device, let volume = SystemLevels.volume(of: device) else { return }
        let muted = SystemLevels.isMuted(device)
        let level = muted ? 0 : volume
        let symbol = switch level {
        case 0: "speaker.slash.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
        flash(.volume, symbol: symbol, title: "Volume", level: level, detail: muted ? "Muted" : nil)
    }

    // MARK: Keys

    private func startKeyTap() {
        guard !keyTap.start() else { return }
        tapRetry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AccessibilityPermission.isTrusted, self.keyTap.start() else { return }
                self.tapRetry?.invalidate()
                self.tapRetry = nil
            }
        }
    }

    /// The key fires before the system applies the change; read the level a moment later.
    private func keyPressed(_ key: MediaKeyTap.Key) {
        if case let .capsLock(on) = key {
            // The event already carries the new state.
            flash(.capsLock, symbol: on ? "capslock.fill" : "capslock", title: "Caps Lock", level: on ? 1 : 0,
                  detail: on ? "On" : "Off", duration: Self.capsLockDuration)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self, isRunning else { return }
            switch key {
            case .brightness:
                guard let level = SystemLevels.displayBrightness() else { return }
                flash(.brightness, symbol: level < 0.5 ? "sun.min.fill" : "sun.max.fill", title: "Brightness", level: level)
            case .keyboardBacklight:
                guard let level = SystemLevels.keyboardBacklight() else { return }
                flash(.keyboardBacklight, symbol: level == 0 ? "light.min" : "light.max", title: "Keyboard", level: level)
            case .capsLock:
                break
            }
        }
    }

    private func flash(
        _ kind: Activity.HUDKind, symbol: String, title: String, level: Double, detail: String? = nil,
        duration: Duration = HUDSource.duration
    ) {
        center?.flash(Activity(
            id: UUID(),
            kind: .hud(kind),
            symbol: symbol,
            title: title,
            detail: detail ?? "\(Int((level * 100).rounded()))%",
            status: .running,
            progress: .level(level),
            updatedAt: Date(),
            presentation: .transient(duration)
        ))
    }

    // MARK: System HUD

    private func observeReplaceSetting() {
        let replaces = withObservationTracking {
            AppSettings.shared.replacesSystemHUD
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.observeReplaceSetting()
            }
        }
        setSuppressing(replaces)
    }

    private func setSuppressing(_ suppress: Bool) {
        guard suppress != isSuppressing else { return }
        isSuppressing = suppress
        if suppress { SystemHUDSuppressor.suppress() } else { SystemHUDSuppressor.restore() }
    }
}
