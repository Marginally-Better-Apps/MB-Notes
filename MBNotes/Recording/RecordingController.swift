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
        /// Asking for the microphone and spinning up the engine; the button is disabled.
        case starting
        case recording
        case paused
        case processing(String)

        var isCapturing: Bool { self == .recording || self == .paused }
    }

    let package: NotePackage
    weak var editor: EditorModel?

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var level: Float = 0
    private(set) var levelHistory: [Float] = []
    private(set) var liveSegments: [Transcript.Segment] = []
    private(set) var volatileText = ""
    /// Why there is no live transcript yet ("Downloading the speech model…"), or nil.
    private(set) var transcriptionNotice: String?
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
    private var summary: RecordingSummary?
    private var pauseStartedAt: Date?
    private var resumeAfterInterruption = false
    private var ticker: Timer?
    private var updateTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
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
        state = .starting
        stopPlayback()
        let number = editor.manifest.recordings.count + 1
        let id = UUID()
        let audioFile = "recordings/\(id.uuidString).caf"
        guard let url = package.fileURL(audioFile) else {
            editor.errorMessage = "Couldn't create the recording file inside this note."
            state = .idle
            return
        }
        let recorder = LiveRecorder(fileURL: url, locale: Locale(identifier: UserDefaults.standard.string(forKey: "transcriptionLocale") ?? Locale.current.identifier))
        do {
            try await recorder.start()
        } catch {
            editor.errorMessage = error.localizedDescription
            state = .idle
            return
        }
        guard state == .starting else {
            // Cancelled while starting (for example the note closed).
            _ = await recorder.stop()
            return
        }
        self.recorder = recorder
        var summary = RecordingSummary(id: id, title: "Recording \(number)", startedAt: recorder.startedAt, duration: 0, audioFile: audioFile, inProgress: true)
        // Listed in the note right away, so a crash mid-lecture leaves a recoverable recording.
        editor.manifest.recordings.append(summary)
        editor.save()
        summary.duration = 0
        self.summary = summary
        liveSegments = []
        volatileText = ""
        transcriptionNotice = nil
        elapsed = 0
        levelHistory = []
        state = .recording

        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickRecording() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer

        updateTask = Task { [weak self] in
            for await update in recorder.updates {
                guard let self else { return }
                self.liveSegments.append(contentsOf: update.finalized)
                self.volatileText = update.volatileText
            }
        }
        eventTask = Task { [weak self] in
            for await event in recorder.events {
                guard let self else { return }
                self.handle(event)
            }
        }
        if UserDefaults.standard.object(forKey: "liveTranscription") as? Bool ?? true {
            transcriptionNotice = "Starting live transcript…"
            Task { await recorder.startTranscription() }
        }
    }

    private func tickRecording() {
        guard let recorder, let summary, state.isCapturing else { return }
        if state == .recording {
            elapsed = summary.audioTime(for: Date())
        }
        level = recorder.level
        levelHistory = recorder.levelHistory
    }

    private func handle(_ event: LiveRecorder.Event) {
        switch event {
        case .interrupted:
            if state == .recording {
                resumeAfterInterruption = true
                pause()
            }
        case .interruptionEnded(let shouldResume):
            if shouldResume, resumeAfterInterruption { resume() }
            resumeAfterInterruption = false
        case .transcription(let ready, let message):
            transcriptionNotice = ready ? nil : message
        }
    }

    func pause() {
        guard state == .recording, let recorder else { return }
        recorder.pause()
        pauseStartedAt = Date()
        state = .paused
    }

    func resume() {
        guard state == .paused, let recorder, let pauseStartedAt, var summary else { return }
        do {
            try recorder.resume()
        } catch {
            editor?.errorMessage = error.localizedDescription
            return
        }
        let start = pauseStartedAt.timeIntervalSince(summary.startedAt)
        summary.pauses.append(Transcript.Span(start: start, end: Date().timeIntervalSince(summary.startedAt)))
        self.summary = summary
        self.pauseStartedAt = nil
        state = .recording
    }

    func togglePause() {
        state == .paused ? resume() : pause()
    }

    func stop() async {
        guard state.isCapturing, let recorder, var summary, let editor else { return }
        if state == .paused { resume() }
        ticker?.invalidate()
        state = .processing("Finishing transcript…")
        let duration = await recorder.stop()
        await updateTask?.value
        await eventTask?.value
        summary.duration = duration
        summary.inProgress = false
        var transcript = Transcript(recordingID: summary.id, startedAt: summary.startedAt, duration: duration, locale: recorder.locale.identifier, engine: "apple.speech")
        transcript.segments = liveSegments
        if let index = editor.manifest.recordings.firstIndex(where: { $0.id == summary.id }) {
            editor.manifest.recordings[index] = summary
        } else {
            editor.manifest.recordings.append(summary)
        }
        editor.save()
        save(transcript, for: summary)
        self.recorder = nil
        self.summary = nil
        volatileText = ""
        level = 0
        await process(summary)
    }

    /// Finishes a recording that was running when the app was killed.
    static func recover(_ summary: RecordingSummary, in package: NotePackage) -> RecordingSummary? {
        guard summary.inProgress, let url = package.fileURL(summary.audioPath), let file = try? AVAudioFile(forReading: url) else { return nil }
        var fixed = summary
        fixed.duration = Double(file.length) / file.fileFormat.sampleRate
        fixed.inProgress = false
        return fixed
    }

    /// Runs on-device post-processing for the steps the user has enabled with models that are on.
    func process(_ summary: RecordingSummary) async {
        guard let transcript = transcript(for: summary), let audio = package.fileURL(summary.audioPath), let enhanced = package.fileURL(summary.enhancedAudioPath) else {
            state = .idle
            return
        }
        let defaults = UserDefaults.standard
        let models = ModelManager.shared
        var steps: RecordingProcessor.Steps = []
        if defaults.object(forKey: "process.retranscribe") as? Bool ?? true, models.isUsable(.voz) { steps.insert(.retranscribe) }
        if defaults.object(forKey: "process.speakers") as? Bool ?? true, models.isUsable(.diarizer) { steps.insert(.speakers) }
        if defaults.object(forKey: "process.fillers") as? Bool ?? true, models.isUsable(.uhm) { steps.insert(.fillers) }
        if defaults.object(forKey: "process.clean") as? Bool ?? false, models.isEnabled(.clear) {
            models.ensureSmallModel(.clear)
            if models.isUsable(.clear) { steps.insert(.cleanAudio) }
        }
        guard !steps.isEmpty else {
            state = .idle
            return
        }
        state = .processing("Improving transcript…")
        let processed = await RecordingProcessor.process(audioURL: audio, enhancedURL: enhanced, transcript: transcript, steps: steps) { message in
            Task { @MainActor [weak self] in
                if case .processing = self?.state { self?.state = .processing(message) }
            }
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
        do {
            try package.writeTranscript(transcript, for: summary)
        } catch {
            editor?.errorMessage = "Couldn't save the transcript: \(error.localizedDescription)"
        }
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

    /// Stops anything in flight when the note closes.
    func shutDown() {
        stopPlayback()
        if state == .starting { state = .idle }
        if state.isCapturing { Task { await stop() } }
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
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        playTicker = timer
        updateReplay()
    }

    func pausePlayback() {
        player?.pause()
        isPlaying = false
        playTicker?.invalidate()
    }

    func togglePlay(_ recording: RecordingSummary) {
        if playingID == recording.id, isPlaying { pausePlayback() } else { play(recording) }
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
        guard let recording = recordings.first(where: { date >= $0.startedAt && date <= $0.wallClock(forAudioTime: $0.duration).addingTimeInterval(5) }) else { return }
        play(recording, from: recording.audioTime(for: date) - 2)
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        playTicker?.invalidate()
        isPlaying = false
        playingID = nil
        playbackTime = 0
        editor?.canvas?.showReplay(until: nil, recording: nil)
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
            canvas.showReplay(until: nil, recording: nil)
            return
        }
        canvas.showReplay(until: recording.wallClock(forAudioTime: playbackTime), recording: recording)
    }
}
