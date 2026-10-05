import NoteEngine
import NoteIntelligence
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @AppStorage(AppearancePreference.storageKey) private var appearanceID = AppearancePreference.system.rawValue
    @AppStorage(AppTheme.matchIconKey) private var matchIcon = true
    @AppStorage("pageSize") private var pageSize = "letter"
    @AppStorage("pageScrollAxis") private var pageScrollAxis = "horizontal"
    @AppStorage("fingerDrawing") private var fingerDrawing = !UIPencilInteraction.prefersPencilOnlyDrawing
    @AppStorage("shapeSnapping") private var shapeSnapping = true
    @AppStorage("tapUndoGestures") private var tapUndoGestures = true
    @AppStorage("liveTranscription") private var liveTranscription = true
    @AppStorage("process.retranscribe") private var retranscribe = true
    @AppStorage("process.speakers") private var speakers = true
    @AppStorage("process.fillers") private var fillers = true
    @AppStorage("process.clean") private var cleanAudio = false
    @AppStorage("playCleanAudio") private var playCleanAudio = true
    @State private var models = ModelManager.shared

    var body: some View {
        Form {
            Section("Appearance") {
                NavigationLink { ThemePicker() } label: {
                    HStack {
                        Label("Theme", systemImage: "paintpalette")
                        Spacer()
                        Circle().fill(theme.accent).frame(width: 18, height: 18)
                        Text(theme.name).foregroundStyle(.secondary)
                    }
                }
                Picker(selection: $appearanceID) {
                    ForEach(AppearancePreference.allCases) { Text($0.title).tag($0.rawValue) }
                } label: {
                    Label("Appearance", systemImage: "circle.lefthalf.filled")
                }
                Toggle(isOn: $matchIcon) { Label("Match App Icon to Theme", systemImage: "app") }
                    .onChange(of: matchIcon) { if matchIcon { theme.applyIconIfNeeded() } }
            }

            Section {
                Picker(selection: $pageScrollAxis) {
                    Text("Side by Side").tag("horizontal")
                    Text("Continuous").tag("vertical")
                } label: {
                    Label("Pages", systemImage: "rectangle.portrait.on.rectangle.portrait")
                }
                Picker(selection: $pageSize) {
                    Text("Letter").tag("letter")
                    Text("A4").tag("a4")
                    Text("A5").tag("a5")
                } label: {
                    Label("New Page Size", systemImage: "doc")
                }
                Toggle(isOn: $fingerDrawing) { Label("Draw with Finger", systemImage: "hand.draw") }
                Toggle(isOn: $shapeSnapping) { Label("Snap Shapes", systemImage: "square.on.circle") }
            } header: {
                Text("Writing")
            } footer: {
                Text("With Snap Shapes on, draw a shape and pause before lifting to turn it into a clean line, arrow, polygon, or ellipse.")
            }

            Section {
                Toggle(isOn: $tapUndoGestures) { Label("Tap to Undo and Redo", systemImage: "hand.tap") }
            } header: {
                Text("Gestures")
            } footer: {
                Text("Tap with two fingers to undo and three to redo. Hold to keep going. Double-tap with a finger to zoom. Pinch to zoom anywhere.")
            }

            Section {
                Toggle(isOn: $liveTranscription) { Label("Live Transcript", systemImage: "text.bubble") }
                modelToggle("Improve Transcript Afterward", systemImage: "text.badge.checkmark", isOn: $retranscribe, model: .voz)
                modelToggle("Label Speakers", systemImage: "person.2", isOn: $speakers, model: .diarizer)
                modelToggle("Find Filler Words", systemImage: "scissors", isOn: $fillers, model: .uhm)
                modelToggle("Clean Up Audio", systemImage: "wand.and.sparkles", isOn: $cleanAudio, model: .clear)
                Toggle(isOn: $playCleanAudio) { Label("Play Cleaned-Up Audio", systemImage: "speaker.wave.2") }
            } header: {
                Text("Recording")
            } footer: {
                Text("Live transcripts use Apple's on-device speech recognition. The other steps run after you stop, using the on-device models below. Recordings never leave your device.")
            }

            Section("Intelligence") {
                NavigationLink { AISettingsView() } label: { Label("AI", systemImage: "sparkles") }
                NavigationLink { ModelsView() } label: { Label("On-Device Models", systemImage: "cpu") }
            }

            Section("Content") {
                NavigationLink { PacksView() } label: { Label("Packs", systemImage: "shippingbox") }
            }

            Section {
                NavigationLink { AboutView() } label: { Label("About MB Notes", systemImage: "info.circle") }
            }
        }
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done", role: .confirm) { dismiss() } }
        }
    }

    /// A feature toggle that reads as off when its model is turned off, rather than a second switch.
    private func modelToggle(_ title: String, systemImage: String, isOn: Binding<Bool>, model: OnDeviceModel) -> some View {
        let available = models.isEnabled(model)
        return Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: systemImage)
                if !available {
                    Text("\(model.name) is turned off in On-Device Models").font(.caption).foregroundStyle(.secondary)
                } else if !models.phase(model).isReady {
                    Text("Downloads \(model.name) when first needed").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(!available)
    }
}

/// Pick a color theme. The app re-tints immediately; the icon changes once, on the way out.
struct ThemePicker: View {
    @AppStorage(AppTheme.storageKey) private var themeID = AppTheme.default.rawValue
    @AppStorage(AppTheme.matchIconKey) private var matchIcon = true
    @Environment(\.scenePhase) private var scenePhase
    @State private var iconError: String?

    var body: some View {
        List {
            Section {
                ForEach(AppTheme.allCases) { theme in
                    Button { themeID = theme.rawValue } label: {
                        HStack(spacing: 14) {
                            Image(theme.previewImage)
                                .resizable()
                                .frame(width: 44, height: 44)
                                .clipShape(.rect(cornerRadius: 44 * 0.2237, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 44 * 0.2237, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
                            Text(theme.name)
                            Spacer()
                            HStack(spacing: 4) {
                                Circle().fill(Color(hex: theme.light.accent)).frame(width: 14, height: 14)
                                Circle().fill(Color(hex: theme.light.secondaryAccent)).frame(width: 14, height: 14)
                            }
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.tint)
                                .opacity(themeID == theme.rawValue ? 1 : 0)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(themeID == theme.rawValue ? .isSelected : [])
                }
            } footer: {
                if let iconError {
                    Text(iconError)
                } else if matchIcon {
                    Text("The app icon follows the theme. iOS will confirm the icon change when you leave this screen.")
                }
            }
        }
        .navigationTitle("Theme")
        .sensoryFeedback(.selection, trigger: themeID)
        .onDisappear(perform: applyIcon)
    }

    private func applyIcon() {
        guard scenePhase == .active else { return }
        (AppTheme(rawValue: themeID) ?? .default).applyIconIfNeeded { error in
            Task { @MainActor in iconError = error?.localizedDescription }
        }
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
                    NavigationLink("Choose and Download a Model") { ModelsView() }
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
                    SecureField("API Key", text: $ai.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if let preset = ProviderPreset.all.first(where: { $0.id == ai.presetID }), let keyURL = preset.keyURL, let url = URL(string: keyURL) {
                        Link("Get a \(preset.name) Key", destination: url)
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
                        .accessibilityLabel("Load Models")
                    }
                    if !models.isEmpty {
                        Picker("Available Models", selection: $ai.model) {
                            ForEach(models, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.navigationLink)
                    }
                    if let modelError {
                        Text(modelError).font(.footnote).foregroundStyle(.secondary)
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

struct AboutView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Image(theme.previewImage)
                        .resizable()
                        .frame(width: 96, height: 96)
                        .clipShape(.rect(cornerRadius: 96 * 0.2237, style: .continuous))
                    Text("MB Notes").font(.title2.weight(.semibold))
                    Text("Marginally better notes. Free and open source, for everyone.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical)
            }
            Section("Open Source") {
                Link("Source Code on GitHub", destination: URL(string: "https://github.com/Marginally-Better-Apps/MB-Notes")!)
                Link("Make a Pack", destination: URL(string: "https://github.com/Marginally-Better-Apps/MB-Notes/blob/main/docs/PACKS.md")!)
                Text("MB Notes is released under the MIT License. Built-in papers, covers, and stickers were made for MB Notes and are public domain (CC0). Emoji are drawn by your device's system font.")
                    .font(.footnote)
            }
            Section {
                Link("Powered by Desert Ant Labs", destination: URL(string: "https://desertant.com")!)
                Text("Shape recognition, Voz transcription, Clear audio cleanup, Uhm filler detection, Gist tags, and Title suggestions use on-device models by Desert Ant Labs under the Desert Ant Labs Source-Available License. Their SDK sends an anonymous monthly-active-device count with no notes, audio, or other content.")
                    .font(.footnote)
                Text("Speaker labels use FluidAudio (Apache-2.0) with pyannote community models. Local language models run with MLX Swift (MIT) and come from Hugging Face under each model's own license.")
                    .font(.footnote)
            } header: {
                Text("Credits")
            }
            Section {
                Text("Your notes are plain files in the Files app under On My iPhone or iPad › MB Notes. Recordings, transcripts, and handwriting recognition stay on this device. AI features send note text only to the provider you choose, only when you use them.")
                    .font(.footnote)
            } header: {
                Text("Privacy")
            }
        }
        .navigationTitle("About")
    }
}
