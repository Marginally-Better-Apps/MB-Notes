import Foundation
import Security

public struct AIMessage: Codable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable { case system, user, assistant }
    public var role: Role
    public var content: String

    public init(_ role: Role, _ content: String) {
        self.role = role
        self.content = content
    }
}

/// Anything that can stream a chat completion.
public protocol AIProvider: Sendable {
    var displayName: String { get }
    func stream(_ messages: [AIMessage]) -> AsyncThrowingStream<String, Error>
}

public extension AIProvider {
    func complete(_ messages: [AIMessage]) async throws -> String {
        var output = ""
        for try await chunk in stream(messages) { output += chunk }
        return output
    }
}

public enum AIError: LocalizedError {
    case notConfigured
    case http(Int, String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Choose an AI provider in Settings first."
        case .http(let code, let body): return "The AI provider returned HTTP \(code). \(body.prefix(240))"
        case .unavailable(let reason): return reason
        }
    }
}

// MARK: - Presets

/// A known OpenAI-compatible endpoint. Users can also enter any base URL.
public struct ProviderPreset: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let baseURL: String
    public let suggestedModel: String
    public let needsKey: Bool
    public let keyURL: String?
    public let note: String?

    public static let all: [ProviderPreset] = [
        ProviderPreset(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1", suggestedModel: "gpt-5-mini", needsKey: true, keyURL: "https://platform.openai.com/api-keys", note: nil),
        ProviderPreset(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", suggestedModel: "openai/gpt-5-mini", needsKey: true, keyURL: "https://openrouter.ai/keys", note: "One key for hundreds of models, including free ones."),
        ProviderPreset(id: "anthropic", name: "Anthropic", baseURL: "https://api.anthropic.com/v1", suggestedModel: "claude-sonnet-5-5", needsKey: true, keyURL: "https://console.anthropic.com/settings/keys", note: "Uses Anthropic's OpenAI-compatible endpoint."),
        ProviderPreset(id: "gemini", name: "Google Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", suggestedModel: "gemini-2.5-flash", needsKey: true, keyURL: "https://aistudio.google.com/apikey", note: nil),
        ProviderPreset(id: "groq", name: "Groq", baseURL: "https://api.groq.com/openai/v1", suggestedModel: "llama-3.3-70b-versatile", needsKey: true, keyURL: "https://console.groq.com/keys", note: "Very fast responses."),
        ProviderPreset(id: "mistral", name: "Mistral", baseURL: "https://api.mistral.ai/v1", suggestedModel: "mistral-small-latest", needsKey: true, keyURL: "https://console.mistral.ai/api-keys", note: nil),
        ProviderPreset(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", suggestedModel: "deepseek-chat", needsKey: true, keyURL: "https://platform.deepseek.com/api_keys", note: nil),
        ProviderPreset(id: "xai", name: "xAI", baseURL: "https://api.x.ai/v1", suggestedModel: "grok-4-fast", needsKey: true, keyURL: "https://console.x.ai", note: nil),
        ProviderPreset(id: "together", name: "Together AI", baseURL: "https://api.together.xyz/v1", suggestedModel: "meta-llama/Llama-3.3-70B-Instruct-Turbo", needsKey: true, keyURL: "https://api.together.ai/settings/api-keys", note: nil),
        ProviderPreset(id: "ollama", name: "Ollama (your computer)", baseURL: "http://192.168.1.10:11434/v1", suggestedModel: "llama3.2", needsKey: false, keyURL: nil, note: "Replace the address with your computer's IP on the same Wi-Fi."),
        ProviderPreset(id: "lmstudio", name: "LM Studio (your computer)", baseURL: "http://192.168.1.10:1234/v1", suggestedModel: "", needsKey: false, keyURL: nil, note: "Turn on “Serve on local network” in LM Studio."),
        ProviderPreset(id: "custom", name: "Custom", baseURL: "", suggestedModel: "", needsKey: true, keyURL: nil, note: "Any server that speaks the OpenAI chat completions API."),
    ]
}

// MARK: - OpenAI-compatible

public struct OpenAICompatibleProvider: AIProvider {
    public let baseURL: URL
    public let apiKey: String?
    public let model: String
    public var displayName: String { model }

    public init(baseURL: URL, apiKey: String?, model: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            // Anthropic's compatibility layer also reads its native header.
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        request.setValue("MB Notes", forHTTPHeaderField: "X-Title")
        request.setValue("https://github.com/Marginally-Better-Apps/MB-Notes", forHTTPHeaderField: "HTTP-Referer")
        request.httpBody = body
        return request
    }

    /// Model ids from the provider's `/models` endpoint, sorted.
    public func listModels() async throws -> [String] {
        let (data, response) = try await URLSession.shared.data(for: request("models"))
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw AIError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        struct List: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]?
            let models: [Model]?
        }
        let list = try JSONDecoder().decode(List.self, from: data)
        return Array(Set((list.data ?? list.models ?? []).map(\.id))).sorted()
    }

    public func stream(_ messages: [AIMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    struct Body: Encodable {
                        let model: String
                        let messages: [AIMessage]
                        let stream: Bool
                    }
                    let body = try JSONEncoder().encode(Body(model: model, messages: messages, stream: true))
                    let (bytes, response) = try await URLSession.shared.bytes(for: request("chat/completions", method: "POST", body: body))
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var text = ""
                        for try await line in bytes.lines { text += line }
                        throw AIError.http(http.statusCode, text)
                    }
                    struct Chunk: Decodable {
                        struct Choice: Decodable {
                            struct Delta: Decodable { let content: String? }
                            let delta: Delta?
                        }
                        let choices: [Choice]?
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8), let chunk = try? JSONDecoder().decode(Chunk.self, from: data) else { continue }
                        if let text = chunk.choices?.first?.delta?.content, !text.isEmpty { continuation.yield(text) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Keychain

/// Stores API keys in the device keychain, never in the library or backups.
public enum Keychain {
    private static let service = "com.marginallybetter.notes.ai"

    public static func set(_ value: String?, for account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    public static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
