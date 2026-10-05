import NoteEngine
import NoteIntelligence
import SwiftUI

/// A compact glass bar for the active recording, post-processing, or playback.
struct RecordingBar: View {
    let recording: RecordingController
    var openTranscript: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            switch recording.state {
            case .starting:
                ProgressView().controlSize(.small)
                Text("Starting…").font(.subheadline)
                Spacer(minLength: 0)
            case .recording, .paused:
                captureControls
            case .processing(let message):
                ProgressView().controlSize(.small)
                Text(message).font(.subheadline).lineLimit(1)
                Spacer(minLength: 0)
            case .idle:
                if let id = recording.playingID, let summary = recording.recordings.first(where: { $0.id == id }) {
                    playbackControls(summary)
                }
            }
            Button(action: openTranscript) { Image(systemName: "text.quote") }
                .accessibilityLabel("Show Transcript")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .frame(height: 48)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private var captureControls: some View {
        HStack(spacing: 10) {
            RecordingDot(paused: recording.state == .paused)
            Text(Duration.seconds(recording.elapsed).formatted(.time(pattern: .hourMinuteSecond)))
                .font(.subheadline.weight(.semibold).monospacedDigit())
            Waveform(levels: recording.levelHistory, paused: recording.state == .paused)
                .frame(width: 80, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(recording.state == .paused ? "Paused" : "Recording")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(recording.state == .paused ? .secondary : Color.red)
                Text(liveLine).font(.caption).lineLimit(1).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { recording.togglePause() } label: {
                Image(systemName: recording.state == .paused ? "record.circle" : "pause.fill").frame(width: 28, height: 28)
            }
            .accessibilityLabel(recording.state == .paused ? "Resume Recording" : "Pause Recording")
            Button { Task { await recording.stop() } } label: {
                Image(systemName: "stop.fill").frame(width: 28, height: 28).foregroundStyle(.red)
            }
            .accessibilityLabel("Stop Recording")
        }
    }

    private func playbackControls(_ summary: RecordingSummary) -> some View {
        HStack(spacing: 10) {
            Button { recording.skip(-10) } label: { Image(systemName: "gobackward.10") }
            Button { recording.togglePlay(summary) } label: {
                Image(systemName: recording.isPlaying ? "pause.fill" : "play.fill").frame(width: 24)
            }
            .accessibilityLabel(recording.isPlaying ? "Pause" : "Play")
            Button { recording.skip(10) } label: { Image(systemName: "goforward.10") }
            Slider(value: Binding(get: { recording.playbackTime }, set: { recording.seek(to: $0) }), in: 0...max(1, summary.duration))
            Text(Duration.seconds(recording.playbackTime).formatted(.time(pattern: .minuteSecond)))
                .font(.caption.monospacedDigit())
            Button { recording.stopPlayback() } label: { Image(systemName: "xmark") }
                .accessibilityLabel("Stop Playback")
        }
    }

    private var liveLine: String {
        if let notice = recording.transcriptionNotice { return notice }
        let finalized = recording.liveSegments.last?.text ?? ""
        let text = recording.volatileText.isEmpty ? finalized : recording.volatileText
        return text.isEmpty ? "Listening…" : text
    }
}

/// A red dot that pulses while recording and sits still while paused.
struct RecordingDot: View {
    let paused: Bool
    @State private var on = true

    var body: some View {
        Circle()
            .fill(paused ? Color.secondary : Color.red)
            .frame(width: 10, height: 10)
            .opacity(paused || on ? 1 : 0.3)
            .animation(paused ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
            .onAppear { on.toggle() }
            .accessibilityHidden(true)
    }
}

/// Recent levels as thin bars that scroll by.
struct Waveform: View {
    let levels: [Float]
    var paused = false

    var body: some View {
        Canvas { context, size in
            let count = Int(size.width / 3)
            let slice = levels.suffix(count)
            for (i, level) in slice.enumerated() {
                let x = size.width - CGFloat(slice.count - i) * 3
                let h = max(2, CGFloat(level) * size.height)
                let rect = CGRect(x: x, y: (size.height - h) / 2, width: 2, height: h)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(paused ? .secondary : .red))
            }
        }
        .accessibilityHidden(true)
    }
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case recordings, ai
    var id: String { rawValue }
    var title: String { self == .recordings ? "Recordings" : "AI" }
    var systemImage: String { self == .recordings ? "waveform" : "sparkles" }
}

/// The side panel: recordings with transcripts, and AI help for the note.
struct NoteInspector: View {
    let model: EditorModel
    @Binding var tab: InspectorTab

    var body: some View {
        Group {
            switch tab {
            case .recordings: RecordingsPanel(model: model)
            case .ai: AIPanel(model: model)
            }
        }
        .safeAreaInset(edge: .top) {
            // Lives in the content rather than the toolbar: toolbar items of inspector content
            // merge into the host's navigation bar even while the inspector is hidden.
            Picker("Panel", selection: $tab) {
                ForEach(InspectorTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}

struct RecordingsPanel: View {
    let model: EditorModel
    @State private var selected: UUID?

    private var recording: RecordingController { model.recording }

    var body: some View {
        if recording.state.isCapturing {
            LiveTranscriptView(recording: recording)
        } else if let id = selected ?? recording.recordings.last?.id, let summary = recording.recordings.first(where: { $0.id == id }) {
            VStack(spacing: 0) {
                if recording.recordings.count > 1 {
                    Picker("Recording", selection: Binding(get: { id }, set: { selected = $0 })) {
                        ForEach(recording.recordings) { Text($0.title).tag($0.id) }
                    }
                    .padding(.horizontal)
                }
                TranscriptView(recording: recording, summary: summary)
            }
        } else {
            ContentUnavailableView("No Recordings", systemImage: "waveform", description: Text("Tap the record button while you take notes. You'll get a transcript, speaker labels, and playback that shows what you wrote at each moment."))
        }
    }
}

struct LiveTranscriptView: View {
    let recording: RecordingController

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let notice = recording.transcriptionNotice {
                        Label(notice, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(recording.liveSegments) { segment in
                        Text(segment.text).id(segment.id)
                    }
                    if !recording.volatileText.isEmpty {
                        Text(recording.volatileText).foregroundStyle(.secondary).id("volatile")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .onChange(of: recording.liveSegments.count) {
                withAnimation { proxy.scrollTo(recording.liveSegments.last?.id, anchor: .bottom) }
            }
        }
    }
}

/// A transcript with speaker colors, filters, and tap-to-seek.
struct TranscriptView: View {
    let recording: RecordingController
    let summary: RecordingSummary
    @State private var editingSpeaker: Transcript.Speaker?
    @State private var speakerName = ""
    @State private var renaming = false
    @State private var title = ""
    @State private var confirmDelete = false

    var body: some View {
        let transcript = recording.transcript(for: summary)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text(summary.title).font(.headline)
                    Text("\(summary.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(Duration.seconds(summary.duration).formatted(.time(pattern: .minuteSecond)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { recording.togglePlay(summary) } label: {
                    Image(systemName: recording.playingID == summary.id && recording.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                Menu {
                    Button { title = summary.title; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                    Toggle("Replay Ink While Playing", isOn: Binding(get: { recording.replayInk }, set: { recording.replayInk = $0 }))
                    Toggle("Skip Filler Words", isOn: Binding(get: { recording.skipFillers }, set: { recording.skipFillers = $0 }))
                    Picker("Speed", selection: Binding(get: { recording.playbackRate }, set: { recording.playbackRate = $0 })) {
                        ForEach([0.75, 1, 1.25, 1.5, 2] as [Float], id: \.self) { Text("\($0.formatted())×").tag($0) }
                    }
                    Button { Task { await recording.process(summary) } } label: { Label("Improve with On-Device Models", systemImage: "wand.and.sparkles") }
                    Divider()
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete Recording", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle").frame(width: 36, height: 36)
                }
            }
            .padding(.horizontal)

            if let transcript, !transcript.speakers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(transcript.speakers) { speaker in
                            let hidden = transcript.hiddenSpeakers.contains(speaker.id)
                            Button {
                                recording.toggleSpeakerHidden(speaker.id, in: summary)
                            } label: {
                                Label(speaker.name, systemImage: hidden ? "eye.slash" : "person.wave.2.fill")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .foregroundStyle(hidden ? .secondary : Color.white)
                                    .background(hidden ? Color.secondary.opacity(0.15) : Color(hex: speaker.color), in: .capsule)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Rename Speaker") { speakerName = speaker.name; editingSpeaker = speaker }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                Text("Tap a speaker to hide them from the transcript, search, and AI. Hold to rename.")
                    .font(.caption2).foregroundStyle(.secondary).padding(.horizontal)
            }

            if let transcript {
                transcriptList(transcript)
            } else {
                ContentUnavailableView("No Transcript", systemImage: "text.badge.xmark", description: Text("Transcription wasn't available for this recording."))
            }
        }
        .alert("Rename Speaker", isPresented: Binding(get: { editingSpeaker != nil }, set: { if !$0 { editingSpeaker = nil } })) {
            TextField("Name", text: $speakerName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { if let s = editingSpeaker { recording.renameSpeaker(s.id, to: speakerName, in: summary) } }
        }
        .alert("Rename Recording", isPresented: $renaming) {
            TextField("Title", text: $title)
            Button("Cancel", role: .cancel) {}
            Button("Save") { recording.rename(summary, to: title) }
        }
        .confirmationDialog("Delete “\(summary.title)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Recording", role: .destructive) { recording.delete(summary) }
        } message: {
            Text("The audio and transcript are removed from this note.")
        }
    }

    private func transcriptList(_ transcript: Transcript) -> some View {
        let speakers = Dictionary(uniqueKeysWithValues: transcript.speakers.map { ($0.id, $0) })
        let visible = transcript.segments.filter { $0.speaker.map { !transcript.hiddenSpeakers.contains($0) } ?? true }
        let playing = recording.playingID == summary.id
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if visible.isEmpty {
                        Text(transcript.segments.isEmpty ? "No speech was transcribed." : "Every speaker is hidden.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(visible) { segment in
                        let active = playing && recording.playbackTime >= segment.start && recording.playbackTime < segment.end
                        Button {
                            recording.play(summary, from: segment.start)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Text(Duration.seconds(segment.start).formatted(.time(pattern: .minuteSecond)))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 44, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    if let id = segment.speaker, let speaker = speakers[id] {
                                        Text(speaker.name).font(.caption.weight(.bold)).foregroundStyle(Color(hex: speaker.color))
                                    }
                                    Text(highlighted(segment, active: active)).multilineTextAlignment(.leading)
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(active ? Color.accentColor.opacity(0.12) : Color.clear, in: .rect(cornerRadius: Radius.tile))
                        }
                        .buttonStyle(.plain)
                        .id(segment.id)
                    }
                }
                .padding(.horizontal)
            }
            .onChange(of: activeSegmentID(visible)) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    private func activeSegmentID(_ segments: [Transcript.Segment]) -> UUID? {
        guard recording.playingID == summary.id else { return nil }
        return segments.first { recording.playbackTime >= $0.start && recording.playbackTime < $0.end }?.id
    }

    /// Bolds the word being spoken.
    private func highlighted(_ segment: Transcript.Segment, active: Bool) -> AttributedString {
        guard active, !segment.words.isEmpty else { return AttributedString(segment.text) }
        var result = AttributedString()
        for (index, word) in segment.words.enumerated() {
            var piece = AttributedString(word.text)
            if recording.playbackTime >= word.start && recording.playbackTime < word.end {
                piece.font = .body.bold()
                piece.foregroundColor = .accentColor
            }
            result += piece
            if index < segment.words.count - 1 { result += AttributedString(" ") }
        }
        return result
    }
}
