import AVFoundation
import AppKit
import Observation
import SwiftUI

/// Hotkey dictation. The hotkey (or the card's Stop) toggles it: while it listens, a persistent activity
/// shows the live transcript and microphone level; stopping types the text into the front app.
/// Needs only the Microphone permission; recognition runs on-device through `SpeechAnalyzer`.
final class DictationSource: ActivitySource {
    static let id = "dictation"
    static let info = ActivitySourceInfo(
        title: "Dictation",
        detail: "A hotkey starts dictating; press it again to type the text into the front app. Recognised on this Mac.",
        symbol: "mic.fill",
        tint: .pink,
        permission: .microphone
    )

    static let stopAction = "stop"
    static let cancelAction = "cancel"

    private enum Phase {
        case idle
        /// Permissions, model download, engine start.
        case preparing
        case listening
        /// Waiting for the recogniser's last words.
        case finishing
    }

    private weak var center: ActivityCenter?
    private var isRunning = false
    private var phase = Phase.idle
    /// Bumped on every begin/stop/cancel so a late async step knows its session is gone.
    private var generation = 0
    private var activityID = UUID()
    private var engine: DictationEngine?
    private var capture: MicrophoneCapture?
    private var interruption: NSObjectProtocol?
    private var sessionTask: Task<Void, Never>?
    private var timer: Timer?

    private var transcript = ""
    private var level = 0.0
    private var published: (level: Double, detail: String)?

    // MARK: ActivitySource

    func start(center: ActivityCenter) {
        self.center = center
        isRunning = true
        ActionRouter.shared.register(owner: Activity.Kind.dictation.owner, ActionRouter.Handler(
            perform: { [weak self] _, actionID in
                switch actionID {
                case Self.stopAction: self?.stopAndInsert()
                case Self.cancelAction: self?.cancel()
                default: break
                }
            },
            reply: nil
        ))
        HotkeyManager.shared.setHandler({ [weak self] in self?.toggle() }, for: .dictation)
        observeHotkey()
        requestPermissions()
    }

    func stop() {
        isRunning = false
        endSession(dismissing: true)
        HotkeyManager.shared.unregister(slot: .dictation)
        HotkeyManager.shared.setHandler(nil, for: .dictation)
        ActionRouter.shared.unregister(owner: Activity.Kind.dictation.owner)
        self.center = nil
    }

    // MARK: Hotkey

    /// Registers the configured hotkey and re-registers whenever the setting changes.
    private func observeHotkey() {
        guard isRunning else { return }
        let shortcut = withObservationTracking {
            AppSettings.shared.dictationHotkey
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeHotkey() }
        }
        if !HotkeyManager.shared.register(shortcut, slot: .dictation) {
            NSLog("Perch: \(shortcut.displayString) is not available for dictation; another app or Perch shortcut owns it.")
        }
    }

    /// Start, or stop and insert; a second press while still preparing cancels.
    private func toggle() {
        guard isRunning else { return }
        switch phase {
        case .idle: begin()
        case .preparing: cancel()
        case .listening: stopAndInsert()
        case .finishing: break
        }
    }

    // MARK: Permissions

    /// The prompt on first use of the source, so the first hotkey press does not stall on a dialog.
    private func requestPermissions() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { @Sendable _ in }
        }
    }

    private func ensureMicrophonePermission() async throws {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        if let problem = DictationError.permissionProblem(microphone: AVCaptureDevice.authorizationStatus(for: .audio)) {
            throw problem
        }
    }

    // MARK: Session

    private func begin() {
        guard isRunning, let center, phase == .idle else { return }
        phase = .preparing
        generation += 1
        let session = generation
        activityID = UUID()
        transcript = ""
        level = 0
        published = nil

        var activity = Activity(
            id: activityID, kind: .dictation, symbol: "mic.fill", title: "Dictation",
            detail: "Starting…", status: .running, progress: .indeterminate, updatedAt: Date(),
            presentation: .persistent
        )
        activity.actions = [Self.cancelButton]
        center.show(activity)

        sessionTask = Task { [weak self] in
            await self?.prepare(session: session)
        }
    }

    private func prepare(session: Int) async {
        let capture = MicrophoneCapture()
        do {
            let engine = try await DictationEngines.make()
            guard session == generation else { return }
            self.engine = engine
            try await ensureMicrophonePermission()
            guard session == generation else { return }
            let format = try capture.inputFormat()
            let sink = try await engine.begin(
                inputFormat: format,
                onText: { [weak self] text in
                    guard let self, session == generation else { return }
                    transcript = text
                },
                onFailure: { [weak self] error in
                    guard let self, session == generation, phase == .preparing || phase == .listening else { return }
                    fail(error)
                },
                status: { [weak self] detail in
                    guard let self, session == generation, phase == .preparing else { return }
                    center?.update(activityID) { $0.detail = detail }
                }
            )
            guard session == generation else {
                await engine.cancel()
                return
            }
            try capture.start(format: format, onBuffer: sink)
            self.capture = capture
            interruption = capture.observeInterruption { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.phase == .listening else { return }
                    self.fail(.interrupted)
                }
            }
            listen()
        } catch {
            guard session == generation else { return }
            fail(error as? DictationError ?? .engine("Dictation failed"))
        }
    }

    private func listen() {
        phase = .listening
        center?.update(activityID) { activity in
            activity.detail = "Listening…"
            activity.progress = .audioLevel(0)
            activity.actions = [Self.stopButton, Self.cancelButton]
        }
        published = (0, "Listening…")
        timer = Timer.scheduledTimer(withTimeInterval: DictationLevel.updateInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// ~15 Hz: smooths the peak the audio thread saw and publishes level and transcript when either visibly changed.
    private func tick() {
        guard phase == .listening, let capture else { return }
        level = DictationLevel.smoothed(previous: level, next: capture.meter.take())
        let shownLevel = DictationLevel.quantized(level)
        let detail = transcript.isEmpty ? "Listening…" : DictationTranscript.tail(transcript)
        guard published?.level != shownLevel || published?.detail != detail else { return }
        published = (shownLevel, detail)
        center?.update(activityID) { activity in
            activity.progress = .audioLevel(shownLevel)
            activity.detail = detail
        }
    }

    /// Stop: the transcript is typed into the front app.
    private func stopAndInsert() {
        guard phase == .listening, let engine else { return }
        phase = .finishing
        let session = generation
        stopCapture()
        center?.update(activityID) { activity in
            activity.detail = "Finishing…"
            activity.actions = []
        }
        sessionTask = Task { [weak self] in
            let text = DictationTranscript.final(await engine.finish())
            guard let self, session == generation else { return }
            complete(with: text)
        }
    }

    private func complete(with text: String) {
        let id = activityID
        defer { endSession(dismissing: false) }
        guard !text.isEmpty else {
            finishCard(id, status: .done, detail: "Nothing heard")
            return
        }
        switch DictationInserter.insert(text) {
        case .pasted:
            finishCard(id, status: .done, detail: DictationTranscript.tail(text))
        case .copied:
            finishCard(id, status: .failed, detail: "Copied; allow Accessibility to paste")
        }
    }

    private func cancel() {
        guard phase != .idle, phase != .finishing else { return }
        endSession(dismissing: true)
    }

    private func fail(_ error: DictationError) {
        let id = activityID
        endSession(dismissing: false)
        finishCard(id, status: .failed, detail: error.message)
    }

    private func finishCard(_ id: UUID, status: Activity.Status, detail: String) {
        center?.update(id) { activity in
            activity.detail = detail
            activity.actions = []
            activity.symbol = status == .failed ? "mic.slash.fill" : "mic.fill"
        }
        center?.finish(id, status: status)
    }

    /// Tears down whatever runs and returns to idle. `dismissing` also removes the card.
    private func endSession(dismissing: Bool) {
        let id = activityID
        let engine = engine
        generation += 1
        phase = .idle
        sessionTask?.cancel()
        sessionTask = nil
        stopCapture()
        self.engine = nil
        if let engine { Task { await engine.cancel() } }
        transcript = ""
        published = nil
        if dismissing { center?.dismiss(id) }
    }

    private func stopCapture() {
        timer?.invalidate()
        timer = nil
        if let interruption { NotificationCenter.default.removeObserver(interruption) }
        interruption = nil
        capture?.stop()
        capture = nil
    }

    private static let stopButton = ActivityAction(id: stopAction, title: "Stop", symbol: "stop.fill")
    private static let cancelButton = ActivityAction(id: cancelAction, title: "Cancel", symbol: "xmark", isDestructive: true)
}
