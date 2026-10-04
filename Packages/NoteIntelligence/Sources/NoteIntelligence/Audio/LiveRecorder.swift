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

    public let fileURL: URL
    public let locale: Locale
    public private(set) var startedAt = Date()
    public let updates: AsyncStream<LiveTranscriptUpdate>
    /// Input level from 0 to 1, for a meter.
    public var level: Float { lock.withLock { _level } }

    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private let updateContinuation: AsyncStream<LiveTranscriptUpdate>.Continuation
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var resultsTask: Task<Void, Never>?
    private let lock = NSLock()
    private var _level: Float = 0

    public init(fileURL: URL, locale: Locale = .current) {
        self.fileURL = fileURL
        self.locale = locale
        (updates, updateContinuation) = AsyncStream.makeStream(of: LiveTranscriptUpdate.self)
    }

    /// Whether live transcription can run for this locale on this device.
    public static func transcriptionLocale(for locale: Locale) async -> Locale? {
        guard SpeechTranscriber.isAvailable else { return nil }
        return await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    }

    public func start(transcribe: Bool) async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw RecorderError.microphoneDenied }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers])
        try session.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInput }

        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        file = try AVAudioFile(forWriting: fileURL, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)

        if transcribe { try await startTranscription() }

        let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false)!
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handle(buffer, mono: monoFormat)
        }
        startedAt = Date()
        engine.prepare()
        try engine.start()
    }

    private func startTranscription() async throws {
        guard let supported = await Self.transcriptionLocale(for: locale) else { return }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        inputContinuation = continuation
        self.transcriber = transcriber
        self.analyzer = analyzer
        try await analyzer.start(inputSequence: stream)

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
    }

    private func handle(_ buffer: AVAudioPCMBuffer, mono: AVAudioFormat) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        var peak: Float = 0
        for i in 0..<frames { peak = max(peak, abs(channel[i])) }
        lock.withLock { _level = min(1, peak * 1.6) }

        // Write the first channel as mono.
        if let monoBuffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength) {
            monoBuffer.frameLength = buffer.frameLength
            monoBuffer.floatChannelData![0].update(from: channel, count: frames)
            try? file?.write(from: monoBuffer)
            feedAnalyzer(monoBuffer)
        }
    }

    private func feedAnalyzer(_ buffer: AVAudioPCMBuffer) {
        guard let inputContinuation, let target = analyzerFormat else { return }
        if buffer.format == target {
            inputContinuation.yield(AnalyzerInput(buffer: buffer))
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
            inputContinuation.yield(AnalyzerInput(buffer: output))
        }
    }

    /// Stops recording and waits for the transcriber to finalize its last words.
    public func stop() async -> TimeInterval {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
        let duration = Date().timeIntervalSince(startedAt)
        inputContinuation?.finish()
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        await resultsTask?.value
        updateContinuation.finish()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return duration
    }
}
