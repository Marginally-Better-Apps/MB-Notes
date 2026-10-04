import NoteEngine
import NoteIntelligence
import SwiftUI

struct SettingsView: View {
    @AppStorage("pageSize") private var pageSize = "letter"
    @AppStorage("fingerDrawing") private var fingerDrawing = !UIPencilInteraction.prefersPencilOnlyDrawing
    @AppStorage("shapeSnapping") private var shapeSnapping = true
    @AppStorage("liveTranscription") private var liveTranscription = true
    @AppStorage("process.retranscribe") private var retranscribe = true
    @AppStorage("process.speakers") private var speakers = true
    @AppStorage("process.fillers") private var fillers = true
    @AppStorage("process.clean") private var cleanAudio = false
    @AppStorage("playCleanAudio") private var playCleanAudio = true

    var body: some View {
        Form {
            Section("Look and feel") {
                NavigationLink { AppIconPicker() } label: {
                    Label("App icon", systemImage: "app.badge")
                }
            }

            Section {
                Toggle("Draw with your finger", isOn: $fingerDrawing)
                Toggle("Snap shapes", isOn: $shapeSnapping)
                Picker("New page size", selection: $pageSize) {
                    Text("Letter").tag("letter")
                    Text("A4").tag("a4")
                    Text("A5").tag("a5")
                }
            } header: {
                Text("Writing")
            } footer: {
                Text("With snapping on, draw a rectangle, circle, triangle, star, or line and pause before lifting to turn it into a clean shape.")
            }

            Section {
                Toggle("Live transcript while recording", isOn: $liveTranscription)
                Toggle("Re-transcribe with Voz", isOn: $retranscribe)
                Toggle("Label speakers", isOn: $speakers)
                Toggle("Find filler words", isOn: $fillers)
                Toggle("Clean up audio after recording", isOn: $cleanAudio)
                Toggle("Play cleaned-up audio", isOn: $playCleanAudio)
            } header: {
                Text("Recording")
            } footer: {
                Text("Live transcripts use Apple's on-device speech recognition. The other steps run after you stop recording, only with models you've downloaded below. Recordings never leave your device.")
            }

            Section("Intelligence") {
                NavigationLink { AISettingsView() } label: {
                    Label("AI", systemImage: "sparkles")
                }
                NavigationLink { ModelsView() } label: {
                    Label("On-device models", systemImage: "cpu")
                }
            }

            Section {
                NavigationLink { AboutView() } label: {
                    Label("About MB Notes", systemImage: "info.circle")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(BrandBackdrop(intensity: 0.4))
        .navigationTitle("Settings")
    }
}

struct AppIconPicker: View {
    @State private var current = AppIconTheme.current
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 20)], spacing: 24) {
                ForEach(AppIconTheme.allCases) { theme in
                    Button {
                        UIApplication.shared.setAlternateIconName(theme.iconName) { failure in
                            Task { @MainActor in
                                if let failure { error = failure.localizedDescription } else { current = theme }
                            }
                        }
                    } label: {
                        VStack(spacing: 8) {
                            Image(theme.previewImage)
                                .resizable()
                                .frame(width: 92, height: 92)
                                .clipShape(.rect(cornerRadius: 22))
                                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                                .overlay(RoundedRectangle(cornerRadius: 24).stroke(Brand.pink, lineWidth: current == theme ? 3 : 0).padding(-5))
                            Text(theme.title).font(.subheadline.weight(current == theme ? .semibold : .regular))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(24)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .background(BrandBackdrop(intensity: 0.4))
        .navigationTitle("App icon")
    }
}

struct AISettingsView: View {
    @State private var ai = AIService.shared
    @State private var models: [String] = []
    @State private var loadingModels = false
    @State private var modelError: String?
    @State private var testResult: String?

    var body: some View {
        Form {
            Section {
                Picker("Use", selection: $ai.backend) {
                    ForEach(AIBackend.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                Text(footer)
            }

            if ai.backend == .apple, let reason = AppleOnDeviceProvider.availability {
                Section { Label(reason, systemImage: "exclamationmark.triangle") }
            }

            if ai.backend == .local {
                Section {
                    NavigationLink("Choose and download a model") { ModelsView() }
                    LabeledContent("Model", value: ModelManager.shared.localModelID)
                } footer: {
                    Text("The model loads only while it's answering and unloads after a short idle period.")
                }
            }

            if ai.backend == .remote {
                Section("Provider") {
                    Picker("Preset", selection: Binding(get: { ai.presetID }, set: { id in
                        if let preset = ProviderPreset.all.first(where: { $0.id == id }) { ai.apply(preset) }
                        models = []
                    })) {
                        ForEach(ProviderPreset.all) { Text($0.name).tag($0.id) }
                    }
                    if let preset = ProviderPreset.all.first(where: { $0.id == ai.presetID }), let note = preset.note {
                        Text(note).font(.footnote).foregroundStyle(.secondary)
                    }
                    TextField("Base URL", text: $ai.baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API key", text: $ai.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if let preset = ProviderPreset.all.first(where: { $0.id == ai.presetID }), let keyURL = preset.keyURL, let url = URL(string: keyURL) {
                        Link("Get a \(preset.name) key", destination: url)
                    }
                }
                Section {
                    HStack {
                        TextField("Model", text: $ai.model)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button {
                            Task { await loadModels() }
                        } label: {
                            if loadingModels { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                        }
                        .accessibilityLabel("Load models")
                    }
                    if !models.isEmpty {
                        Picker("Available models", selection: $ai.model) {
                            ForEach(models, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.navigationLink)
                    }
                    if let modelError {
                        Text(modelError).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("Model")
                } footer: {
                    Text("Your key is stored in this device's keychain. Notes are sent to the provider only when you use an AI feature.")
                }
            }

            if ai.backend != .off {
                Section {
                    Button("Test") {
                        testResult = "…"
                        Task {
                            do {
                                let reply = try await ai.provider?.complete([AIMessage(.user, "Reply with one short, friendly sentence confirming you work.")]) ?? ""
                                testResult = reply
                            } catch {
                                testResult = error.localizedDescription
                            }
                        }
                    }
                    if let testResult { Text(testResult).font(.footnote) }
                }
            }
        }
        .navigationTitle("AI")
    }

    private var footer: String {
        switch ai.backend {
        case .off: return "AI features stay hidden until you choose a provider."
        case .apple: return "Runs privately on this device with Apple Intelligence. Free."
        case .local: return "Runs a small open model from Hugging Face on this device. Private and offline once downloaded."
        case .remote: return "Bring your own key for OpenAI, OpenRouter, Anthropic, Gemini, Groq, or any OpenAI-compatible server, including Ollama or LM Studio on your computer."
        }
    }

    private func loadModels() async {
        loadingModels = true
        modelError = nil
        do {
            models = try await ai.availableRemoteModels()
            if models.isEmpty { modelError = "The provider returned no models." }
        } catch {
            modelError = error.localizedDescription
        }
        loadingModels = false
    }
}

struct ModelsView: View {
    @State private var manager = ModelManager.shared
    @State private var customRepo = ""

    var body: some View {
        List {
            Section {
                ForEach(OnDeviceModel.allCases.filter { $0 != .localLLM }) { model in
                    ModelRow(model: model, manager: manager)
                }
            } header: {
                Text("Note and recording models")
            } footer: {
                Text("Small models download by themselves the first time a feature needs them. Larger ones wait for you. Everything runs on this device.")
            }

            Section {
                ForEach(LocalModelPreset.all) { preset in
                    Button {
                        manager.localModelID = preset.id
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name).font(.body.weight(.medium))
                                Text("\(preset.size) · \(preset.note)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if manager.localModelID == preset.id { Image(systemName: "checkmark").foregroundStyle(Brand.pink) }
                        }
                    }
                    .buttonStyle(.plain)
                }
                HStack {
                    TextField("Any MLX model, e.g. mlx-community/…", text: $customRepo)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Use") { manager.localModelID = customRepo.trimmingCharacters(in: .whitespaces) }
                        .disabled(!customRepo.contains("/"))
                }
                ModelRow(model: .localLLM, manager: manager)
            } header: {
                Text("Local language model")
            } footer: {
                Text("Pick a small Hugging Face model for summaries and questions without the internet. Then choose “On-device model” in Settings › AI.")
            }
        }
        .navigationTitle("On-device models")
        .onAppear { manager.refresh() }
    }
}

private struct ModelRow: View {
    let model: OnDeviceModel
    let manager: ModelManager

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: model.systemImage)
                .font(.title3)
                .foregroundStyle(Brand.gradient)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(model == .localLLM ? manager.localModelID.components(separatedBy: "/").last ?? model.name : model.name)
                        .font(.body.weight(.semibold))
                    Text(model.approximateSize).font(.caption).foregroundStyle(.secondary)
                }
                Text(model.purpose).font(.caption).foregroundStyle(.secondary)
                Text(model.vendor).font(.caption2).foregroundStyle(.tertiary)
                statusView
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var statusView: some View {
        switch manager.status(model) {
        case .ready:
            HStack {
                Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Spacer()
                Button("Delete", role: .destructive) { manager.delete(model) }
            }
            .font(.caption.weight(.semibold))
        case .downloading(let fraction):
            HStack {
                ProgressView(value: fraction)
                Button("Cancel") { manager.cancel(model) }.font(.caption)
            }
        case .notDownloaded:
            Button("Download") { manager.download(model) }
                .buttonStyle(.glass)
                .font(.caption.weight(.semibold))
        case .failed(let message):
            VStack(alignment: .leading) {
                Text(message).font(.caption).foregroundStyle(.red)
                Button("Try again") { manager.download(model) }.font(.caption)
            }
        case .unavailable(let reason):
            Text(reason).font(.caption).foregroundStyle(.secondary)
        }
    }
}
