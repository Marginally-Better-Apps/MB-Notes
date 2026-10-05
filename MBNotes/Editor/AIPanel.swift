import NoteEngine
import NoteIntelligence
import SwiftUI

/// Summaries and questions about the open note, using the provider chosen in Settings.
struct AIPanel: View {
    let model: EditorModel
    @State private var ai = AIService.shared
    @State private var history: [AIMessage] = []
    @State private var streaming = ""
    @State private var question = ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            if !ai.isConfigured {
                ContentUnavailableView {
                    Label("AI Is Off", systemImage: "sparkles")
                } description: {
                    Text("Choose Apple Intelligence, a small on-device model, or your own API key in Settings › AI. MB Notes never sends your notes anywhere until you do.")
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Label(ai.provider?.displayName ?? "", systemImage: ai.backend == .remote ? "network" : "lock.shield")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if !history.isEmpty {
                                    Button("Clear") { history = []; streaming = "" }.font(.caption)
                                }
                            }
                            if history.isEmpty && streaming.isEmpty {
                                suggestions
                            }
                            ForEach(Array(history.enumerated()), id: \.offset) { _, message in
                                bubble(message.content, mine: message.role == .user)
                            }
                            if !streaming.isEmpty {
                                bubble(streaming, mine: false)
                            }
                            if isWorking && streaming.isEmpty {
                                ProgressView().frame(maxWidth: .infinity)
                            }
                            if let error {
                                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding()
                    }
                    .onChange(of: streaming) { proxy.scrollTo("end", anchor: .bottom) }
                }
                inputBar
            }
        }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Ask About This Note").font(.headline).padding(.bottom, 4)
            ForEach(["Summarize this note", "Make flashcards from this note", "What should I review before the exam?", "Explain the hardest idea simply"], id: \.self) { prompt in
                Button {
                    if prompt == "Summarize this note" { summarize() } else { send(prompt) }
                } label: {
                    HStack {
                        Text(prompt)
                        Spacer()
                        Image(systemName: "arrow.up.circle").foregroundStyle(.tint)
                    }
                    .padding(.vertical, 10)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
    }

    private var inputBar: some View {
        HStack {
            TextField("Ask a question", text: $question, axis: .vertical)
                .lineLimit(1...4)
                .onSubmit { send(question) }
            if isWorking {
                Button { task?.cancel() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                    .accessibilityLabel("Stop")
            } else {
                Button { send(question) } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.panel))
        .padding()
    }

    private func bubble(_ text: String, mine: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
                .textSelection(.enabled)
            if !mine, !isWorking || text != streaming {
                Button {
                    addToNote(text)
                } label: {
                    Label("Add to Note", systemImage: "plus.rectangle.portrait").font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            }
        }
        .padding(mine ? 12 : 0)
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .background(mine ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 18, style: .continuous))
    }

    private func summarize() {
        run(label: "Summarize this note") {
            ai.summarize(noteTitle: model.manifest.title, context: await context())
        }
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        question = ""
        let prior = history
        run(label: trimmed) {
            ai.ask(trimmed, noteTitle: model.manifest.title, context: await context(), history: prior)
        }
    }

    private func context() async -> String {
        model.save()
        await model.recognizeAll()
        return model.noteContext()
    }

    private func run(label: String, stream: @escaping () async -> AsyncThrowingStream<String, Error>) {
        error = nil
        history.append(AIMessage(.user, label))
        isWorking = true
        streaming = ""
        task = Task {
            do {
                for try await chunk in await stream() {
                    streaming += chunk
                }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            if !streaming.isEmpty { history.append(AIMessage(.assistant, streaming)) }
            streaming = ""
            isWorking = false
        }
    }

    /// Adds the answer to a new page as a text box.
    private func addToNote(_ text: String) {
        let plain = (try? AttributedString(markdown: text)).map { String($0.characters) } ?? text
        let lined = PaperRef(template: ContentRef(packID: CorePack.id, itemID: "lined"))
        model.addPage(after: model.pageCount - 1, paper: lined)
        let index = model.pageCount - 1
        let size = model.manifest.pages[index].size
        var style = model.textStyle
        style.fontSize = 14
        model.addElement(.text(plain, frame: Rect(x: 72, y: 72, width: size.width - 120, height: size.height - 120), style: style), toPage: index)
    }
}
