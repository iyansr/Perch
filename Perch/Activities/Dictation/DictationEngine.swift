import AVFoundation
import Speech
import Synchronization

/// Where the microphone hands audio to a recogniser. Called on the audio thread.
typealias DictationAudioSink = @Sendable (AVAudioPCMBuffer) -> Void

/// A speech recogniser fed live audio. Everything but the sink runs on the main actor.
protocol DictationEngine: AnyObject {
    /// Whether the engine needs the Speech Recognition permission (only `SFSpeechRecognizer` does).
    var needsSpeechPermission: Bool { get }

    /// Loads the model (downloading it first when missing) and starts the recogniser.
    /// - Parameters:
    ///   - inputFormat: format of the buffers the returned sink will receive.
    ///   - onText: the whole transcript so far, after every change.
    ///   - onFailure: the recogniser failed while running.
    ///   - status: progress worth showing while `begin` waits (a model download).
    /// - Returns: the sink to feed with microphone buffers.
    func begin(
        inputFormat: AVAudioFormat,
        onText: @escaping (String) -> Void,
        onFailure: @escaping (DictationError) -> Void,
        status: @escaping (String) -> Void
    ) async throws -> DictationAudioSink

    /// Ends the audio, waits for the last words and returns the transcript.
    func finish() async -> String

    /// Drops the session without a result.
    func cancel() async
}

enum DictationEngines {
    /// On-device `SpeechAnalyzer` when it supports the user's language, else `SFSpeechRecognizer`.
    static func make(locale: Locale = .current) async -> DictationEngine {
        if let supported = await SpeechAnalyzerEngine.supportedLocale(for: locale) {
            return SpeechAnalyzerEngine(locale: supported)
        }
        return SFSpeechEngine(locale: locale)
    }
}

/// The default input device through `AVAudioEngine`. The tap runs on the audio thread: it feeds the
/// recogniser and a `PeakMeter`, and touches nothing else.
nonisolated final class MicrophoneCapture: @unchecked Sendable {
    let meter = PeakMeter()
    private let engine = AVAudioEngine()
    private var isTapped = false

    /// Format of the buffers the tap delivers; throws when there is no input device.
    func inputFormat() throws -> AVAudioFormat {
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw DictationError.noInput }
        return format
    }

    func start(format: AVAudioFormat, onBuffer: @escaping DictationAudioSink) throws {
        let meter = meter
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            meter.record(DictationLevel.level(of: buffer))
            onBuffer(buffer)
        }
        isTapped = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw DictationError.engine("Microphone could not start")
        }
    }

    func stop() {
        if isTapped { engine.inputNode.removeTap(onBus: 0) }
        isTapped = false
        engine.stop()
    }

    /// The engine's configuration changed under us (device unplugged, default input switched).
    func observeInterruption(_ handler: @escaping @Sendable () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
            handler()
        }
    }
}

// MARK: - SpeechAnalyzer

/// Converts microphone buffers to the analyzer's format and queues them. Used from the audio thread only.
nonisolated private final class AnalyzerFeed: @unchecked Sendable {
    private let converter: AVAudioConverter?
    private let outputFormat: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation

    init(from input: AVAudioFormat, to output: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        converter = input == output ? nil : AVAudioConverter(from: input, to: output)
        outputFormat = output
        self.continuation = continuation
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, converted.frameLength > 0 else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    func finish() { continuation.finish() }
}

/// On-device `SpeechTranscriber`. Results arrive as volatile guesses that a final result then replaces;
/// finals after the first start with a space, so they concatenate as they are.
final class SpeechAnalyzerEngine: DictationEngine {
    let needsSpeechPermission = false

    private let locale: Locale
    private var analyzer: SpeechAnalyzer?
    private var feed: AnalyzerFeed?
    private var resultsTask: Task<Void, Never>?
    private var committed = ""
    private var volatile = ""

    init(locale: Locale) {
        self.locale = locale
    }

    /// The locale the transcriber supports for the user's language, or nil when it has none.
    static func supportedLocale(for locale: Locale) async -> Locale? {
        guard SpeechTranscriber.isAvailable else { return nil }
        return await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    }

    func begin(
        inputFormat: AVAudioFormat,
        onText: @escaping (String) -> Void,
        onFailure: @escaping (DictationError) -> Void,
        status: @escaping (String) -> Void
    ) async throws -> DictationAudioSink {
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        try await ensureModel(for: transcriber, status: status)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: inputFormat) else {
            throw DictationError.noModel
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let feed = AnalyzerFeed(from: inputFormat, to: format, continuation: continuation)
        self.analyzer = analyzer
        self.feed = feed

        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        committed += text
                        volatile = ""
                    } else {
                        volatile = text
                    }
                    onText(committed + volatile)
                }
            } catch {
                if !Task.isCancelled { onFailure(Self.map(error)) }
            }
        }
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            await cancel()
            throw Self.map(error)
        }
        return { buffer in feed.append(buffer) }
    }

    func finish() async -> String {
        feed?.finish()
        feed = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        if let resultsTask {
            await DictationWait.completion(of: resultsTask, timeout: .seconds(3))
        }
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        return committed + volatile
    }

    func cancel() async {
        feed?.finish()
        feed = nil
        resultsTask?.cancel()
        resultsTask = nil
        await analyzer?.cancelAndFinishNow()
        analyzer = nil
    }

    /// Downloads the language model when it is not on this Mac yet.
    private func ensureModel(for transcriber: SpeechTranscriber, status: (String) -> Void) async throws {
        let inventory = await AssetInventory.status(forModules: [transcriber])
        if inventory == .unsupported { throw DictationError.unsupportedLocale }
        let installedLocales = await SpeechTranscriber.installedLocales
        let isInstalled = inventory == .installed
            || installedLocales.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
        guard !isInstalled else { return }
        status("Downloading speech model…")
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw DictationError.noModel
        }
    }

    private static func map(_ error: Error) -> DictationError {
        if let error = error as? DictationError { return error }
        if let speech = error as? SFSpeechError {
            if speech.code == .noModel || speech.code == .assetLocaleNotAllocated { return .noModel }
            if speech.code == .cannotAllocateUnsupportedLocale { return .unsupportedLocale }
        }
        return .engine("Speech recognition failed")
    }
}

// MARK: - Languages SpeechAnalyzer lacks: SFSpeechRecognizer

private nonisolated final class RequestSink: @unchecked Sendable {
    let request: SFSpeechAudioBufferRecognitionRequest

    init(_ request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }
}

/// `SFSpeechRecognizer`, on-device when the language supports it.
final class SFSpeechEngine: DictationEngine {
    let needsSpeechPermission = true

    private let locale: Locale
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latest = ""
    private var isFinal = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(locale: Locale) {
        self.locale = locale
    }

    func begin(
        inputFormat: AVAudioFormat,
        onText: @escaping (String) -> Void,
        onFailure: @escaping (DictationError) -> Void,
        status: @escaping (String) -> Void
    ) async throws -> DictationAudioSink {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { throw DictationError.unsupportedLocale }
        guard recognizer.isAvailable else { throw DictationError.noModel }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request

        task = Self.startTask(recognizer, request) { [weak self] text, final, failed in
            guard let self else { return }
            if let text {
                latest = text
                isFinal = final
                onText(text)
            }
            if final || failed != nil { resume() }
            // An error after the last words (cancelled, no speech) is normal; only a silent failure is reported.
            if let failed, text == nil, latest.isEmpty, !final { onFailure(.engine(failed)) }
        }
        let sink = RequestSink(request)
        return { buffer in sink.request.append(buffer) }
    }

    func finish() async -> String {
        request?.endAudio()
        if task != nil, !isFinal {
            // The recogniser's last result or the deadline, whichever comes first, resumes the waiter.
            let deadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.resume()
            }
            await withCheckedContinuation { waiter = $0 }
            deadline.cancel()
        }
        task?.cancel()
        task = nil
        request = nil
        return latest
    }

    func cancel() async {
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        resume()
    }

    private func resume() {
        let pending = waiter
        waiter = nil
        pending?.resume()
    }

    /// Created outside the main actor so the recogniser's callback queue never hits a main-actor check.
    private nonisolated static func startTask(
        _ recognizer: SFSpeechRecognizer,
        _ request: SFSpeechAudioBufferRecognitionRequest,
        deliver: @escaping @MainActor (String?, Bool, String?) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failed = error?.localizedDescription
            DispatchQueue.main.async {
                MainActor.assumeIsolated { deliver(text, final, failed) }
            }
        }
    }
}

/// Waits for a task with a deadline, without cancelling it: whichever finishes first resumes the caller.
nonisolated enum DictationWait {
    private final class Once: Sendable {
        private let continuation: Mutex<CheckedContinuation<Void, Never>?>

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = Mutex(continuation)
        }

        func fire() {
            continuation.withLock { $0.take() }?.resume()
        }
    }

    static func completion(of task: Task<Void, Never>, timeout: Duration) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = Once(continuation)
            Task.detached {
                await task.value
                once.fire()
            }
            Task.detached {
                try? await Task.sleep(for: timeout)
                once.fire()
            }
        }
    }
}
