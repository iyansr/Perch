import AppKit
import Observation
import SwiftUI

/// Owns one update operation and its window for the lifetime of the application.
@Observable
final class UpdateController: NSObject, NSWindowDelegate {
    static let shared = UpdateController()

    enum State {
        case idle
        case checking
        case current
        case available(UpdateRelease)
        case downloading(UpdateRelease, Double)
        case ready(UpdateRelease, URL)
        case failed(String)
    }

    private(set) var state = State.idle
    private(set) var installationMessage: String?
    private(set) var isPreparingInstall = false
    @ObservationIgnored private var scheduler: Task<Void, Never>?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var canPresent: () -> Bool = { false }
    @ObservationIgnored private var installationBlockReason: () -> String? = { "The updater has not started." }
    @ObservationIgnored private var announced: Set<String> = []
    @ObservationIgnored private var deferredUntil: Date?
    @ObservationIgnored private var handingOff = false
    @ObservationIgnored private let defaults = UserDefaults.standard

    private enum Key {
        static let nextCheck = "perch.updates.nextCheck"
        static let skipped = "perch.updates.skippedVersion"
    }

    static var isSupported: Bool {
        #if DEBUG
        return false
        #else
        return Bundle.main.bundleIdentifier == "id.iyansr.perch"
            && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        #endif
    }

    static var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    var isWorking: Bool {
        switch state {
        case .checking, .downloading: true
        default: false
        }
    }

    func start(canPresent: @escaping () -> Bool, installationBlockReason: @escaping () -> String?) {
        guard Self.isSupported else { return }
        self.canPresent = canPresent
        self.installationBlockReason = installationBlockReason
        observeAutomaticChecks()
        if let report = UpdateInstaller.takeFailureReport() {
            state = .failed("The last update was not installed. \(report)")
            showWindow(activate: true)
        }
    }

    func stop() {
        scheduler?.cancel()
        scheduler = nil
        operation?.cancel()
        operation = nil
        if !handingOff { discardStagedUpdate() }
    }

    private func observeAutomaticChecks() {
        let enabled = withObservationTracking {
            AppSettings.shared.automaticallyChecksForUpdates
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeAutomaticChecks() }
        }
        scheduler?.cancel()
        scheduler = nil
        guard enabled else { return }
        scheduler = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(30))
                while !Task.isCancelled {
                    guard let self else { return }
                    self.scheduledTick()
                    try await Task.sleep(for: .seconds(120))
                }
            } catch { /* Stopping automatic checks cancels the sleep. */ }
        }
    }

    private func scheduledTick() {
        guard AppSettings.shared.automaticallyChecksForUpdates, operation == nil else { return }
        if case let .available(release) = state,
           !announced.contains(release.tag),
           defaults.string(forKey: Key.skipped) != release.version.description,
           let deadline = deferredUntil, Date() <= deadline {
            if canPresent() {
                announced.insert(release.tag)
                deferredUntil = nil
                showWindow(activate: false)
            }
            return
        }
        guard window == nil else { return }
        let next = defaults.object(forKey: Key.nextCheck) as? Date ?? .distantPast
        if Date() >= next { check(manual: false) }
    }

    func checkForUpdates() {
        guard Self.isSupported else { return }
        if isWorking || isReady {
            showWindow(activate: true)
            return
        }
        check(manual: true)
    }

    private var isReady: Bool {
        if case .ready = state { true } else { false }
    }

    private func check(manual: Bool) {
        guard operation == nil,
              let current = UpdateVersion(Self.installedVersion) else { return }
        state = .checking
        installationMessage = nil
        if manual { showWindow(activate: true) }
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.operation = nil }
            do {
                let release = try await UpdateFeed.latest(currentVersion: current)
                try Task.checkCancellation()
                self.defaults.set(Date().addingTimeInterval(86_400), forKey: Key.nextCheck)
                if let release {
                    self.state = .available(release)
                    if !manual, AppSettings.shared.automaticallyChecksForUpdates,
                              self.defaults.string(forKey: Key.skipped) != release.version.description,
                              !self.announced.contains(release.tag) {
                        self.deferredUntil = Date().addingTimeInterval(1_800)
                        if self.canPresent() {
                            self.announced.insert(release.tag)
                            self.deferredUntil = nil
                            self.showWindow(activate: false)
                        }
                    }
                } else {
                    self.state = .current
                }
            } catch is CancellationError {
                self.state = .idle
            } catch {
                if Task.isCancelled {
                    self.state = .idle
                } else {
                    self.defaults.set(Date().addingTimeInterval(7_200), forKey: Key.nextCheck)
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    func download() {
        guard case let .available(release) = state, operation == nil else { return }
        state = .downloading(release, 0)
        installationMessage = nil
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.operation = nil }
            do {
                let staged = try await UpdateInstaller.stage(release, bundleURL: Bundle.main.bundleURL) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, case .downloading = self.state else { return }
                        self.state = .downloading(release, fraction)
                    }
                }
                if Task.isCancelled {
                    UpdateInstaller.discard(stagedApp: staged)
                    self.state = .available(release)
                } else {
                    self.state = .ready(release, staged)
                }
            } catch is CancellationError {
                self.state = .available(release)
            } catch {
                self.state = Task.isCancelled ? .available(release) : .failed(error.localizedDescription)
            }
        }
    }

    func cancelDownload() { operation?.cancel() }

    func installAndRelaunch() {
        guard case let .ready(_, staged) = state, !isPreparingInstall, operation == nil else { return }
        if let reason = installationBlockReason() {
            installationMessage = reason
            return
        }
        installationMessage = nil
        isPreparingInstall = true
        operation = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isPreparingInstall = false
                self.operation = nil
            }
            do {
                let handoff = try await UpdateInstaller.prepareRelaunch(stagedApp: staged, bundleURL: Bundle.main.bundleURL)
                // Work may have started while the helper was being verified and launched.
                if Task.isCancelled {
                    try? handoff.cancel()
                    return
                }
                if let reason = self.installationBlockReason() {
                    try? handoff.cancel()
                    self.installationMessage = reason
                    return
                }
                try handoff.commit()
                self.handingOff = true
                NSApp.terminate(nil)
            } catch is CancellationError {
                return
            } catch {
                self.installationMessage = error.localizedDescription
            }
        }
    }

    func skip() {
        if case let .available(release) = state {
            defaults.set(release.version.description, forKey: Key.skipped)
        }
        window?.close()
    }

    private func discardStagedUpdate() {
        if case let .ready(_, staged) = state {
            UpdateInstaller.discard(stagedApp: staged)
            state = .idle
        }
    }

    private func showWindow(activate: Bool) {
        if let window {
            if activate { NSApp.activate(); window.makeKeyAndOrderFront(nil) }
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 430),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "Perch Updates"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: UpdateWindowView(updater: self))
        window.center()
        self.window = window
        if activate {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        !isPreparingInstall
    }

    func windowWillClose(_ notification: Notification) {
        if !handingOff {
            operation?.cancel()
            discardStagedUpdate()
        }
        window = nil
        deferredUntil = nil
    }
}

private struct UpdateWindowView: View {
    @Bindable var updater: UpdateController

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Perch Updates", systemImage: "arrow.triangle.2.circlepath")
                .font(.title2.bold())
            content
            if let message = updater.installationMessage {
                Text(message).font(.callout).foregroundStyle(.red)
                    .accessibilityLabel("Cannot install: \(message)")
            }
            Spacer(minLength: 0)
            Text("Installed version \(UpdateController.installedVersion)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 480, height: 430, alignment: .topLeading)
    }

    @ViewBuilder private var content: some View {
        switch updater.state {
        case .idle:
            Text("Check for the latest stable release.")
            Button("Check for Updates…", action: updater.checkForUpdates)
        case .checking:
            ProgressView("Checking for updates…")
        case .current:
            Text("Perch is up to date.").font(.headline)
            Text("You’re running the latest stable release.").foregroundStyle(.secondary)
        case let .available(release):
            Text("Perch \(release.version.description) is available.").font(.headline)
            notes(release.notes)
            HStack {
                Button("Skip This Version", action: updater.skip)
                Spacer()
                Button("Download Update", action: updater.download).buttonStyle(.borderedProminent)
            }
        case let .downloading(_, progress):
            ProgressView(value: progress) { Text("Downloading and verifying update…") }
            Text("Perch stays open until you choose Install and Relaunch.").foregroundStyle(.secondary)
            Button("Cancel Download", action: updater.cancelDownload)
        case let .ready(release, _):
            Text("Perch \(release.version.description) is ready.").font(.headline)
            Text("Installation replaces Perch at its current location and restarts it. Your settings and clipboard history stay unchanged.")
            if updater.isPreparingInstall {
                ProgressView("Preparing installation…")
            } else {
                Button("Install and Relaunch", action: updater.installAndRelaunch).buttonStyle(.borderedProminent)
            }
        case let .failed(message):
            Text("Could not update Perch.").font(.headline)
            ScrollView { Text(message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            Button("Try Again", action: updater.checkForUpdates)
        }
    }

    private func notes(_ text: String) -> some View {
        ScrollView {
            Text(text.isEmpty ? "No release notes provided." : text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
        .accessibilityLabel("Release notes")
    }
}
