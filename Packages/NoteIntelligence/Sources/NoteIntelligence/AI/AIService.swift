import Foundation
import Observation

/// Which engine powers AI features. Nothing is sent anywhere until the user picks one.
public enum AIBackend: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case apple
    case local
    case remote

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: return "Off"
        case .apple: return "Apple Intelligence"
        case .local: return "On-device model"
        case .remote: return "Your API key"
        }
    }
}

/// AI settings and the note-level tasks built on them.
@MainActor
@Observable
public final class AIService {
    public static let shared = AIService()

    public var backend: AIBackend { didSet { save() } }
    public var presetID: String { didSet { save() } }
    public var baseURL: String { didSet { save() } }
    public var model: String { didSet { save() } }
    public var apiKey: String {
        didSet { Keychain.set(apiKey, for: "apiKey") }
    }

    private init() {
        let defaults = UserDefaults.standard
        backend = AIBackend(rawValue: defaults.string(forKey: "ai.backend") ?? "") ?? .off
        presetID = defaults.string(forKey: "ai.preset") ?? "openai"
        baseURL = defaults.string(forKey: "ai.baseURL") ?? ProviderPreset.all[0].baseURL
        model = defaults.string(forKey: "ai.model") ?? ProviderPreset.all[0].suggestedModel
        apiKey = Keychain.get("apiKey") ?? ""
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(backend.rawValue, forKey: "ai.backend")
        defaults.set(presetID, forKey: "ai.preset")
        defaults.set(baseURL, forKey: "ai.baseURL")
        defaults.set(model, forKey: "ai.model")
    }

    public func apply(_ preset: ProviderPreset) {
        presetID = preset.id
        if !preset.baseURL.isEmpty { baseURL = preset.baseURL }
        model = preset.suggestedModel
    }

    private var localProvider: LocalMLXProvider?

    /// The configured provider, or nil when AI is off or incomplete.
    public var provider: AIProvider? {
        switch backend {
        case .off:
            return nil
        case .apple:
            return AppleOnDeviceProvider()
        case .local:
            let repo = ModelManager.shared.localModelID
            if localProvider?.repo != repo { localProvider = LocalMLXProvider(repo: repo) }
            return localProvider
        case .remote:
            guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces)), url.scheme != nil, !model.isEmpty else { return nil }
            return OpenAICompatibleProvider(baseURL: url, apiKey: apiKey.isEmpty ? nil : apiKey, model: model)
        }
    }

    public var isConfigured: Bool { provider != nil }

    /// Fetches model ids from the configured endpoint's `/models`.
    public func availableRemoteModels() async throws -> [String] {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces)), url.scheme != nil else { throw AIError.notConfigured }
        return try await OpenAICompatibleProvider(baseURL: url, apiKey: apiKey.isEmpty ? nil : apiKey, model: model).listModels()
    }

    // MARK: Note tasks

    static let systemPrompt = """
    You help a student with their own notes in MB Notes. The notes come from handwriting \
    recognition, typed text, and recording transcripts, so expect recognition mistakes and \
    fix obvious ones silently. Be accurate, concise, and use Markdown headings and bullet \
    lists. Never invent facts that are not in the notes; say so when the notes don't cover something.
    """

    /// Streams a structured summary of the note.
    public func summarize(noteTitle: String, context: String) -> AsyncThrowingStream<String, Error> {
        guard let provider else { return AsyncThrowingStream { $0.finish(throwing: AIError.notConfigured) } }
        return provider.stream([
            AIMessage(.system, Self.systemPrompt),
            AIMessage(.user, "Summarize my notes titled “\(noteTitle)”. Start with a two-sentence overview, then key points, then any terms worth reviewing.\n\n<notes>\n\(context.prefix(60_000))\n</notes>"),
        ])
    }

    /// Streams an answer to a question about the note, continuing the conversation.
    public func ask(_ question: String, noteTitle: String, context: String, history: [AIMessage]) -> AsyncThrowingStream<String, Error> {
        guard let provider else { return AsyncThrowingStream { $0.finish(throwing: AIError.notConfigured) } }
        var messages = [
            AIMessage(.system, Self.systemPrompt),
            AIMessage(.user, "Here are my notes titled “\(noteTitle)”.\n\n<notes>\n\(context.prefix(60_000))\n</notes>"),
            AIMessage(.assistant, "Got it. What would you like to know?"),
        ]
        messages += history
        messages.append(AIMessage(.user, question))
        return provider.stream(messages)
    }
}
