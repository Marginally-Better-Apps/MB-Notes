import Foundation
import FoundationModels
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Apple Intelligence's on-device model, free and private where available.
public struct AppleOnDeviceProvider: AIProvider {
    public var displayName: String { "Apple Intelligence" }

    public init() {}

    public static var availability: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "This device doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in Settings to use it here."
        case .unavailable(.modelNotReady): return "Apple Intelligence is still downloading."
        case .unavailable: return "Apple Intelligence isn't available right now."
        }
    }

    public func stream(_ messages: [AIMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let reason = Self.availability { throw AIError.unavailable(reason) }
                    let instructions = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
                    let prompt = messages.filter { $0.role != .system }.map { message in
                        message.role == .assistant ? "Assistant: \(message.content)" : message.content
                    }.joined(separator: "\n\n")
                    let session = LanguageModelSession(instructions: instructions)
                    var sent = ""
                    for try await snapshot in session.streamResponse(to: prompt) {
                        let full = snapshot.content
                        if full.hasPrefix(sent) {
                            continuation.yield(String(full.dropFirst(sent.count)))
                        }
                        sent = full
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

/// A small Hugging Face model run with MLX. It loads on first use and unloads
/// after a short idle period, so memory is only used while it is working.
public final class LocalMLXProvider: AIProvider, @unchecked Sendable {
    public let repo: String
    public var displayName: String { repo.components(separatedBy: "/").last ?? repo }

    private let lock = NSLock()
    private var container: ModelContainer?
    private var unloadTask: Task<Void, Never>?
    private static let idleUnloadSeconds: UInt64 = 45

    public init(repo: String) {
        self.repo = repo
    }

    private func loadedContainer() async throws -> ModelContainer {
        #if targetEnvironment(simulator)
        throw AIError.unavailable("Local models need a real iPhone or iPad; the simulator has no Metal GPU for MLX.")
        #else
        if let existing = lock.withLock({ container }) { return existing }
        let directory = ModelManager.localModelDirectory(repo)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path) else {
            throw AIError.unavailable("Download \(displayName) in Settings › On-device models first.")
        }
        let loaded = try await #huggingFaceLoadModelContainer(configuration: ModelConfiguration(directory: directory))
        lock.withLock { container = loaded }
        return loaded
        #endif
    }

    private func scheduleUnload() {
        lock.withLock {
            unloadTask?.cancel()
            unloadTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.idleUnloadSeconds * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.unload()
            }
        }
    }

    public func unload() {
        lock.withLock { container = nil }
    }

    public func stream(_ messages: [AIMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let model = try await loadedContainer()
                    let instructions = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
                    let prompt = messages.filter { $0.role != .system }.map(\.content).joined(separator: "\n\n")
                    let session = ChatSession(model, instructions: instructions.isEmpty ? nil : instructions, generateParameters: GenerateParameters(maxTokens: 900, temperature: 0.4))
                    for try await chunk in session.streamResponse(to: prompt) {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                self.scheduleUnload()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
