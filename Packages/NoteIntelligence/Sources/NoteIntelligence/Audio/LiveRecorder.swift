import AVFoundation
import Foundation
import NoteEngine
import Speech

/// What the live transcriber has heard so far.
public struct LiveTranscriptUpdate: Sendable {
    /// Newly finalized segments, in order.
    public var finalized: [Transcript.Segment]
    /// Text still being revised, shown greyed out after the final text.
    public var volatileText: String
}

/// Records the microphone to an AAC file while transcribing on device with
/// Apple's SpeechAnalyzer. Audio never leaves the device.
///
/// Recording starts as soon as the engine does; transcription is attached afterwards
/// so a speech-model download never delays the first second of a lecture. The file is
/// an AAC-in-CAF, which stays playable if the app dies before `stop()`.
public final class LiveRecorder: @unchecked Sendable {
    public enum RecorderError: LocalizedError {
        case microphoneDenied
        case noInput

        public var errorDescription: String? {
            switch self {
            case .microphoneDenied: return "MB Notes doesn't have microphone access. You can allow it in Settings."
            case .noInput: return "No microphone is available."
            }
        }
    }

    /// Things that happen to a recording while it runs.
    public enum Event: Sendable {
        /// A call, Siri, or another app took the microphone. Recording is paused.
        case interrupted
        /// The interruption ended; `shouldResume` says whether iOS expects us to continue.
        case interruptionEnded(shouldResume: Bool)
        /// Transcription is ready, or could not start (nil when it works).
        case transcription(ready: Bool, message: String?)
    }

    public let fileURL: URL
    public let locale: Locale
    public private(set) var startedAt = Date()
    public let updates: AsyncStream<LiveTranscriptUpdate>
    public let events: AsyncStream<Event>
    /// Input level from 0 to 1, for a meter.
    public var level: Float { lock.withLock { _level } }
    /// Recent peak levels, newest last, for a scrolling waveform.
    public var levelHistory: [Float] { lock.withLock { _history } }

    private let engine = AVAudioEngine()
    private let updateContinuation: AsyncStream<LiveTranscriptUpdate>.Continuation
    private let eventContinuation: AsyncStream<Event>.Continuation
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var resultsTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private let lock = NSLock()
    private var _level: Float = 0
    private var _history: [Float] = []
    private var _file: AVAudioFile?
    private var _paused = false

    public init(fileURL: URL, locale: Locale = .current) {
        self.fileURL = fileURL
        self.locale = locale
        (updates, updateContinuation) = AsyncStream.makeStream(of: LiveTranscriptUpdate.self)
        (events, eventContinuation) = AsyncStream.makeStream(of: Event.self)
    }

    /// Whether live transcription can run for this locale on this device.
    public static func transcriptionLocale(for locale: Locale) async -> Locale? {
        guard SpeechTranscriber.isAvailable else { return nil }
        return await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    }

    /// Asks for the microphone and starts capturing. Returns once audio is flowing.
    public func start() async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw RecorderError.microphoneDenied }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)

        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try installTap()
        startedAt = Date()
        engine.prepare()
        try engine.start()
        observeSession()
    }

    /// Attaches the on-device transcriber. Safe to call after `start`; buffers captured
    /// before it is ready are recorded but not transcribed.
    public func startTranscription() async {
        do {
            guard let supported = await Self.transcriptionLocale(for: locale) else {
                eventContinuation.yield(.transcription(ready: false, message: "Live transcripts aren't available for \(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)."))
                return
            }
            let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                eventContinuation.yield(.transcription(ready: false, message: "Downloading the speech model…"))
                try await request.downloadAndInstall()
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
            try await analyzer.start(inputSequence: stream)
            lock.withLock {
                analyzerFormat = format
                inputContinuation = continuation
                self.transcriber = transcriber
                self.analyzer = analyzer
            }
            resultsTask = Task { [updateContinuation] in
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        if result.isFinal {
                            guard !text.isEmpty else { continue }
                            var words: [Transcript.Word] = []
                            for run in result.text.runs {
                                guard let range = run.audioTimeRange else { continue }
                                let word = String(result.text[run.range].characters).trimmingCharacters(in: .whitespaces)
                                if !word.isEmpty { words.append(.init(text: word, start: range.start.seconds, end: range.end.seconds)) }
                            }
                            let segment = Transcript.Segment(start: result.range.start.seconds, end: result.range.end.seconds, text: text, words: words)
                            updateContinuation.yield(LiveTranscriptUpdate(finalized: [segment], volatileText: ""))
                        } else {
                            updateContinuation.yield(LiveTranscriptUpdate(finalized: [], volatileText: text))
                        }
                    }
                } catch {
                    // Transcription stopping early still leaves a usable recording.
                }
            }
            eventContinuation.yield(.transcription(ready: true, message: nil))
        } catch {
            eventContinuation.yield(.transcription(ready: false, message: error.localizedDescription))
        }
    }

    // MARK: Capture

    private func installTap() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInput }
        let file = try lock.withLock { () throws -> AVAudioFile in
            if let existing = _file { return existing }
            // CAF finalizes nothing at the end, so a crash leaves a playable file.
            let file = try AVAudioFile(forWriting: fileURL, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            _file = file
            return file
        }
        let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false)!
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handle(buffer, mono: monoFormat, file: file)
        }
    }

    private func handle(_ buffer: AVAudioPCMBuffer, mono: AVAudioFormat, file: AVAudioFile) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        var peak: Float = 0
        for i in 0..<frames { peak = max(peak, abs(channel[i])) }
        let paused: Bool = lock.withLock {
            _level = min(1, peak * 1.6)
            _history.append(_level)
            if _history.count > 240 { _history.removeFirst(_history.count - 240) }
            return _paused
        }
        guard !paused else { return }

        // Write the first channel as mono.
        if let monoBuffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength) {
            monoBuffer.frameLength = buffer.frameLength
            monoBuffer.floatChannelData![0].update(from: channel, count: frames)
            try? file.write(from: monoBuffer)
            feedAnalyzer(monoBuffer)
        }
    }

    private func feedAnalyzer(_ buffer: AVAudioPCMBuffer) {
        let (continuation, target) = lock.withLock { (inputContinuation, analyzerFormat) }
        guard let continuation, let target else { return }
        if buffer.format == target {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, output.frameLength > 0 {
            continuation.yield(AnalyzerInput(buffer: output))
        }
    }

    // MARK: Pausing and interruptions

    public var isPaused: Bool { lock.withLock { _paused } }

    public func pause() {
        lock.withLock { _paused = true }
        engine.pause()
    }

    public func resume() throws {
        lock.withLock { _paused = false }
        if !engine.isRunning { try engine.start() }
    }

    private func observeSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            guard let self, let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                self.lock.withLock { self._paused = true }
                self.eventContinuation.yield(.interrupted)
            case .ended:
                let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                self.eventContinuation.yield(.interruptionEnded(shouldResume: options.contains(.shouldResume)))
            @unknown default:
                break
            }
        })
        // Headphones unplugged, AirPods connected: the input format may change, so re-tap.
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            try? self.installTap()
            if !self.isPaused, !self.engine.isRunning {
                self.engine.prepare()
                try? self.engine.start()
            }
        })
    }

    /// Stops recording and waits for the transcriber to finalize its last words.
    public func stop() async -> TimeInterval {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let file = lock.withLock { () -> AVAudioFile? in
            let f = _file
            _file = nil
            return f
        }
        let duration = file.map { Double($0.length) / $0.fileFormat.sampleRate } ?? Date().timeIntervalSince(startedAt)
        let continuation = lock.withLock { inputContinuation }
        continuation?.finish()
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        await resultsTask?.value
        updateContinuation.finish()
        eventContinuation.finish()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return duration
    }
}
