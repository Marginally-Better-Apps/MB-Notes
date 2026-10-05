import Clear
import FluidAudio
import Foundation
import NoteEngine
import Uhm
import Voz

/// Improves a finished recording with on-device models. Each step runs only if
/// its model is downloaded and the user enabled it; failures skip the step.
public enum RecordingProcessor {
    public struct Steps: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// Re-transcribe with Voz for better accuracy and word timings.
        public static let retranscribe = Steps(rawValue: 1 << 0)
        /// Label speakers with FluidAudio's diarizer.
        public static let speakers = Steps(rawValue: 1 << 1)
        /// Find filler words with Uhm.
        public static let fillers = Steps(rawValue: 1 << 2)
        /// Write a cleaned-up copy of the audio with Clear.
        public static let cleanAudio = Steps(rawValue: 1 << 3)

        public static let all: Steps = [.retranscribe, .speakers, .fillers, .cleanAudio]
    }

    public static let speakerColors = ["#4C3AD6", "#F76CA0", "#2EB8A6", "#FF8A45", "#8056F6", "#3E8EDE", "#E5484D", "#3FB37F"]

    public static func process(
        audioURL: URL,
        enhancedURL: URL,
        transcript original: Transcript,
        steps: Steps,
        progress: @Sendable @escaping (String) -> Void = { _ in }
    ) async -> Transcript {
        var transcript = original

        // Callers build `steps` from models that are downloaded and switched on, so each
        // step only re-checks the files it needs.
        if steps.contains(.retranscribe), Voz.isDownloaded() {
            progress("Transcribing with Voz…")
            if let voz = try? await Voz(), let result = try? await voz.transcribe(audioURL), !result.words.isEmpty {
                let words = result.words.map { Transcript.Word(text: $0.text, start: $0.start, end: $0.end) }
                transcript.segments = segments(from: words)
                transcript.engine = "desertant.voz"
            }
        }

        if steps.contains(.speakers), ModelManager.directoryHasFiles(ModelManager.diarizerDirectory) {
            progress("Finding speakers…")
            let manager = OfflineDiarizerManager(config: .default)
            do {
                try await manager.prepareModels(directory: ModelManager.diarizerDirectory)
                let result = try await manager.process(audioURL)
                let turns = result.segments.map { (speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
                apply(turns: turns, to: &transcript)
            } catch {
                progress("Speaker labels skipped: \(error.localizedDescription)")
            }
        }

        if steps.contains(.fillers), Uhm().isDownloaded() {
            progress("Finding filler words…")
            if let result = try? await Uhm().analyze(audioURL: audioURL) {
                transcript.fillers = result.fillers.map { Transcript.Span(start: $0.start, end: $0.end) }
            }
        }

        if steps.contains(.cleanAudio), Clear().isDownloaded() {
            progress("Cleaning up audio…")
            try? FileManager.default.removeItem(at: enhancedURL)
            _ = try? await Clear().enhance(path: audioURL.path, to: enhancedURL.path)
        }

        transcript.isProcessed = true
        return transcript
    }

    /// Groups words into readable segments at pauses and sentence ends.
    public static func segments(from words: [Transcript.Word]) -> [Transcript.Segment] {
        var segments: [Transcript.Segment] = []
        var current: [Transcript.Word] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            segments.append(Transcript.Segment(start: first.start, end: last.end, text: current.map(\.text).joined(separator: " "), words: current))
            current = []
        }
        for word in words {
            if let last = current.last {
                let pause = word.start - last.end
                let sentenceEnd = last.text.last.map { ".?!".contains($0) } ?? false
                if pause > 0.9 || (sentenceEnd && current.count >= 8) || current.count >= 45 { flush() }
            }
            current.append(word)
        }
        flush()
        return segments
    }

    /// Assigns speakers to words by time, splitting segments where the speaker changes.
    public static func apply(turns: [(speaker: String, start: Double, end: Double)], to transcript: inout Transcript) {
        guard !turns.isEmpty else { return }
        var ids: [String: String] = [:]
        for turn in turns.sorted(by: { $0.start < $1.start }) where ids[turn.speaker] == nil {
            ids[turn.speaker] = "S\(ids.count + 1)"
        }
        func speaker(at time: Double) -> String? {
            if let hit = turns.first(where: { time >= $0.start && time <= $0.end }) { return ids[hit.speaker] }
            let nearest = turns.min { min(abs($0.start - time), abs($0.end - time)) < min(abs($1.start - time), abs($1.end - time)) }
            return nearest.flatMap { ids[$0.speaker] }
        }

        var result: [Transcript.Segment] = []
        for segment in transcript.segments {
            guard !segment.words.isEmpty else {
                var labeled = segment
                labeled.speaker = speaker(at: (segment.start + segment.end) / 2)
                result.append(labeled)
                continue
            }
            var run: [Transcript.Word] = []
            var runSpeaker: String?
            func flush() {
                guard let first = run.first, let last = run.last else { return }
                result.append(Transcript.Segment(start: first.start, end: last.end, text: run.map(\.text).joined(separator: " "), speaker: runSpeaker, words: run))
                run = []
            }
            for word in segment.words {
                let who = speaker(at: (word.start + word.end) / 2)
                if who != runSpeaker, !run.isEmpty { flush() }
                runSpeaker = who
                run.append(word)
            }
            flush()
        }
        transcript.segments = result
        let existing = Dictionary(uniqueKeysWithValues: transcript.speakers.map { ($0.id, $0) })
        transcript.speakers = ids.values.sorted { (Int($0.dropFirst()) ?? 0) < (Int($1.dropFirst()) ?? 0) }.enumerated().map { index, id in
            existing[id] ?? Transcript.Speaker(id: id, name: "Speaker \(index + 1)", color: speakerColors[index % speakerColors.count])
        }
    }
}
