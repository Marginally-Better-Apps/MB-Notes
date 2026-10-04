import AVFoundation
import NoteEngine
import NoteIntelligence
import Observation
import SwiftUI

/// Records lectures into the open note and plays them back with the ink you wrote.
@MainActor
@Observable
final class RecordingController {
    enum State: Equatable {
        case idle
        case recording
        case processing(String)
    }

    let package: NotePackage
    weak var editor: EditorModel?

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var level: Float = 0
    private(set) var liveSegments: [Transcript.Segment] = []
    private(set) var volatileText = ""
    private(set) var transcripts: [UUID: Transcript] = [:]

    // Playback
    private(set) var playingID: UUID?
    private(set) var isPlaying = false
    private(set) var playbackTime: TimeInterval = 0
    var playbackRate: Float = 1 { didSet { player?.rate = playbackRate } }
    var skipFillers = UserDefaults.standard.bool(forKey: "skipFillers") {
        didSet { UserDefaults.standard.set(skipFillers, forKey: "skipFillers") }
    }
    var replayInk = true {
        didSet { updateReplay() }
    }

    private var recorder: LiveRecorder?
    private var recordingSummary: RecordingSummary?
    private var ticker: Timer?
    private var player: AVAudioPlayer?
    private var playTicker: Timer?

    init(package: NotePackage) {
        self.package = package
    }

    var recordings: [RecordingSummary] { editor?.manifest.recordings ?? [] }

    func transcript(for recording: RecordingSummary) -> Transcript? {
        if let cached = transcripts[recording.id] { return cached }
        let loaded = package.readTranscript(recording)
        if let loaded { transcripts[recording.id] = loaded }
        return loaded
    }

    // MARK: Recording

    func start() async {
        guard state == .idle, let editor else { return }
        stopPlayback()
        let number = editor.manifest.recordings.count + 1
        let summary = RecordingSummary(title: "Recording \(number)", startedAt: Date(), duration: 0)
        guard let url = package.fileURL(summary.audioPath) else { return }
        let recorder = LiveRecorder(fileURL: url, locale: Locale(identifier: UserDefaults.standard.string(forKey: "transcriptionLocale") ?? Locale.current.identifier))
        do {
            try await recorder.start(transcribe: UserDefaults.standard.object(forKey: "liveTranscription") as? Bool ?? true)
        } catch {
            editor.errorMessage = error.localizedDescription
            return
        }
        self.recorder = recorder
        recordingSummary = RecordingSummary(id: summary.id, title: summary.title, startedAt: recorder.startedAt, duration: 0)
        liveSegments = []
        volatileText = ""
        elapsed = 0
        state = .recording
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder else { return }
                self.elapsed = Date().timeIntervalSince(recorder.startedAt)
                self.level = recorder.level
            }
        }
        Task {
            for await update in recorder.updates {
                liveSegments.append(contentsOf: update.finalized)
                volatileText = update.volatileText
            }
        }
    }

    func stop() async {
        guard state == .recording, let recorder, var summary = recordingSummary, let editor else { return }
        ticker?.invalidate()
        state = .processing("Finishing transcript…")
        let duration = await recorder.stop()
        // Let the update loop drain the last finalized results.
        try? await Task.sleep(for: .milliseconds(200))
        summary.duration = duration
        var transcript = Transcript(recordingID: summary.id, startedAt: summary.startedAt, duration: duration, locale: recorder.locale.identifier, engine: "apple.speech")
        transcript.segments = liveSegments
        editor.manifest.recordings.append(summary)
        editor.save()
        save(transcript, for: summary)
        self.recorder = nil
        recordingSummary = nil
        volatileText = ""
        await process(summary)
    }

    /// Runs on-device post-processing that the user has enabled.
    func process(_ summary: RecordingSummary) async {
        guard let transcript = transcript(for: summary), let audio = package.fileURL(summary.audioPath), let enhanced = package.fileURL(summary.enhancedAudioPath) else {
            state = .idle
            return
        }
        let defaults = UserDefaults.standard
        var steps: RecordingProcessor.Steps = []
        if defaults.object(forKey: "process.retranscribe") as? Bool ?? true { steps.insert(.retranscribe) }
        if defaults.object(forKey: "process.speakers") as? Bool ?? true { steps.insert(.speakers) }
        if defaults.object(forKey: "process.fillers") as? Bool ?? true { steps.insert(.fillers) }
        if defaults.object(forKey: "process.clean") as? Bool ?? false { steps.insert(.cleanAudio) }
        state = .processing("Improving transcript…")
        let processed = await RecordingProcessor.process(audioURL: audio, enhancedURL: enhanced, transcript: transcript, steps: steps) { message in
            Task { @MainActor in self.state = .processing(message) }
        }
        save(processed, for: summary)

        // Name the recording from its content when the Title model is available.
        if let card = await TextInsights.title(for: processed.visibleText(labelSpeakers: false)), let editor,
           let index = editor.manifest.recordings.firstIndex(where: { $0.id == summary.id }) {
            editor.manifest.recordings[index].title = card.title
            editor.scheduleSave()
        }
        state = .idle
    }

    func save(_ transcript: Transcript, for summary: RecordingSummary) {
        transcripts[summary.id] = transcript
        try? package.writeTranscript(transcript, for: summary)
    }

    func rename(_ recording: RecordingSummary, to title: String) {
        guard let editor, let index = editor.manifest.recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        editor.manifest.recordings[index].title = title
        editor.scheduleSave()
    }

    func delete(_ recording: RecordingSummary) {
        guard let editor else { return }
        if playingID == recording.id { stopPlayback() }
        editor.manifest.recordings.removeAll { $0.id == recording.id }
        for path in [recording.audioPath, recording.transcriptPath, recording.enhancedAudioPath] {
            if let url = package.fileURL(path) { try? FileManager.default.removeItem(at: url) }
        }
        transcripts[recording.id] = nil
        editor.save()
    }

    func renameSpeaker(_ id: String, to name: String, in recording: RecordingSummary) {
        guard var transcript = transcript(for: recording), let index = transcript.speakers.firstIndex(where: { $0.id == id }) else { return }
        transcript.speakers[index].name = name
        save(transcript, for: recording)
    }

    func toggleSpeakerHidden(_ id: String, in recording: RecordingSummary) {
        guard var transcript = transcript(for: recording) else { return }
        if transcript.hiddenSpeakers.contains(id) {
            transcript.hiddenSpeakers.removeAll { $0 == id }
        } else {
            transcript.hiddenSpeakers.append(id)
        }
        save(transcript, for: recording)
    }

    // MARK: Playback

    func play(_ recording: RecordingSummary, from time: TimeInterval? = nil) {
        if playingID != recording.id {
            stopPlayback()
            let useClean = UserDefaults.standard.object(forKey: "playCleanAudio") as? Bool ?? true
            let enhanced = package.fileURL(recording.enhancedAudioPath).flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            guard let url = (useClean ? enhanced : nil) ?? package.fileURL(recording.audioPath) else { return }
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try AVAudioSession.sharedInstance().setActive(true)
                player = try AVAudioPlayer(contentsOf: url)
            } catch {
                editor?.errorMessage = error.localizedDescription
                return
            }
            player?.enableRate = true
            player?.rate = playbackRate
            playingID = recording.id
        }
        if let time { player?.currentTime = max(0, time) }
        player?.play()
        isPlaying = true
        playTicker?.invalidate()
        playTicker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        updateReplay()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        playTicker?.invalidate()
    }

    func togglePlay(_ recording: RecordingSummary) {
        if playingID == recording.id, isPlaying { pause() } else { play(recording) }
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, time), player.duration)
        playbackTime = player.currentTime
        updateReplay()
    }

    func skip(_ seconds: TimeInterval) {
        seek(to: playbackTime + seconds)
    }

    /// Jumps to the moment a stroke was written, a little before it.
    func seek(toStrokeDate date: Date) {
        guard let recording = recordings.first(where: { date >= $0.startedAt && date <= $0.startedAt.addingTimeInterval($0.duration + 5) }) else { return }
        play(recording, from: date.timeIntervalSince(recording.startedAt) - 2)
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        playTicker?.invalidate()
        isPlaying = false
        playingID = nil
        playbackTime = 0
        editor?.canvas?.showReplay(until: nil, recordingStart: .distantPast, recordingEnd: .distantPast)
    }

    private func tick() {
        guard let player else { return }
        playbackTime = player.currentTime
        if !player.isPlaying, isPlaying {
            isPlaying = false
            playTicker?.invalidate()
        }
        if skipFillers, let id = playingID, let fillers = transcripts[id]?.fillers,
           let filler = fillers.first(where: { playbackTime >= $0.start && playbackTime < $0.end - 0.05 }) {
            player.currentTime = filler.end
        }
        updateReplay()
    }

    private func updateReplay() {
        guard let editor, let canvas = editor.canvas else { return }
        guard replayInk, let id = playingID, let recording = recordings.first(where: { $0.id == id }) else {
            canvas.showReplay(until: nil, recordingStart: .distantPast, recordingEnd: .distantPast)
            return
        }
        canvas.showReplay(until: recording.startedAt.addingTimeInterval(playbackTime), recordingStart: recording.startedAt, recordingEnd: recording.startedAt.addingTimeInterval(recording.duration))
    }
}
