import NoteEngine
import NoteIntelligence
import SwiftUI

/// A compact glass bar for the active recording or playback.
struct RecordingBar: View {
    let recording: RecordingController
    var openTranscript: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            switch recording.state {
            case .recording:
                LevelMeter(level: recording.level)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recording · \(Duration.seconds(recording.elapsed).formatted(.time(pattern: .minuteSecond)))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                    Text(liveLine)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            case .processing(let message):
                ProgressView()
                Text(message).font(.caption.weight(.medium))
                Spacer(minLength: 0)
            case .idle:
                if let id = recording.playingID, let summary = recording.recordings.first(where: { $0.id == id }) {
                    Button { recording.skip(-10) } label: { Image(systemName: "gobackward.10") }
                    Button { recording.togglePlay(summary) } label: {
                        Image(systemName: recording.isPlaying ? "pause.fill" : "play.fill").frame(width: 24)
                    }
                    Button { recording.skip(10) } label: { Image(systemName: "goforward.10") }
                    Slider(value: Binding(get: { recording.playbackTime }, set: { recording.seek(to: $0) }), in: 0...max(1, summary.duration))
                    Text(Duration.seconds(recording.playbackTime).formatted(.time(pattern: .minuteSecond)))
                        .font(.caption.monospacedDigit())
                    Button { recording.stopPlayback() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Stop playback")
                }
            }
            Button(action: openTranscript) { Image(systemName: "text.quote") }
                .accessibilityLabel("Show transcript")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .frame(height: 44)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private var liveLine: String {
        let finalized = recording.liveSegments.last?.text ?? ""
        let text = recording.volatileText.isEmpty ? finalized : recording.volatileText
        return text.isEmpty ? "Listening…" : text
    }
}

struct LevelMeter: View {
    let level: Float

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5) { i in
                Capsule()
                    .fill(Float(i) / 5 < level ? Color.red : Color.secondary.opacity(0.3))
                    .frame(width: 3, height: CGFloat(8 + i * 3))
            }
        }
        .animation(.easeOut(duration: 0.1), value: level)
    }
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case recordings, ai
    var id: String { rawValue }
    var title: String { self == .recordings ? "Recordings" : "AI" }
}

/// The side panel: recordings with transcripts, and AI help for the note.
struct NoteInspector: View {
    let model: EditorModel
    @Binding var tab: InspectorTab

    var body: some View {
        VStack(spacing: 0) {
            Picker("Panel", selection: $tab) {
                ForEach(InspectorTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()
            switch tab {
            case .recordings: RecordingsPanel(model: model)
            case .ai: AIPanel(model: model)
            }
        }
    }
}

struct RecordingsPanel: View {
    let model: EditorModel
    @State private var selected: UUID?

    private var recording: RecordingController { model.recording }

    var body: some View {
        if recording.state == .recording {
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
            ContentUnavailableView("No recordings yet", systemImage: "waveform", description: Text("Tap the record button while you take notes. You'll get a transcript, speaker labels, and playback that shows what you wrote at each moment."))
        }
    }
}

struct LiveTranscriptView: View {
    let recording: RecordingController

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
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
                .buttonStyle(.glassProminent)
                Menu {
                    Button("Rename") { title = summary.title; renaming = true }
                    Toggle("Replay ink while playing", isOn: Binding(get: { recording.replayInk }, set: { recording.replayInk = $0 }))
                    Toggle("Skip filler words", isOn: Binding(get: { recording.skipFillers }, set: { recording.skipFillers = $0 }))
                    Picker("Speed", selection: Binding(get: { recording.playbackRate }, set: { recording.playbackRate = $0 })) {
                        ForEach([0.75, 1, 1.25, 1.5, 2] as [Float], id: \.self) { Text("\($0.formatted())×").tag($0) }
                    }
                    Button("Improve with on-device models") { Task { await recording.process(summary) } }
                    Button("Delete recording", role: .destructive) { recording.delete(summary) }
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
                                Button("Rename speaker") { speakerName = speaker.name; editingSpeaker = speaker }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                Text("Tap a speaker to hide them from the transcript, search, and AI. Long-press to rename, for example “Professor”.")
                    .font(.caption2).foregroundStyle(.secondary).padding(.horizontal)
            }

            if let transcript {
                transcriptList(transcript)
            } else {
                ContentUnavailableView("No transcript", systemImage: "text.badge.xmark", description: Text("Transcription wasn't available for this recording."))
            }
        }
        .alert("Rename speaker", isPresented: Binding(get: { editingSpeaker != nil }, set: { if !$0 { editingSpeaker = nil } })) {
            TextField("Name", text: $speakerName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { if let s = editingSpeaker { recording.renameSpeaker(s.id, to: speakerName, in: summary) } }
        }
        .alert("Rename recording", isPresented: $renaming) {
            TextField("Title", text: $title)
            Button("Cancel", role: .cancel) {}
            Button("Save") { recording.rename(summary, to: title) }
        }
    }

    private func transcriptList(_ transcript: Transcript) -> some View {
        let speakers = Dictionary(uniqueKeysWithValues: transcript.speakers.map { ($0.id, $0) })
        let visible = transcript.segments.filter { $0.speaker.map { !transcript.hiddenSpeakers.contains($0) } ?? true }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if visible.isEmpty {
                    Text(transcript.segments.isEmpty ? "No speech was transcribed." : "Every speaker is hidden.")
                        .foregroundStyle(.secondary)
                }
                ForEach(visible) { segment in
                    let active = recording.playingID == summary.id && recording.playbackTime >= segment.start && recording.playbackTime < segment.end
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
                                Text(segment.text).multilineTextAlignment(.leading)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(active ? Brand.pink.opacity(0.14) : Color.clear, in: .rect(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }
}
