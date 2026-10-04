import Clear
import FluidAudio
import Foundation
import Gist
import Observation
import Shapes
import Title
import Uhm
import Voz

/// Every on-device model MB Notes can use.
public enum OnDeviceModel: String, CaseIterable, Identifiable, Sendable {
    case shapes, voz, diarizer, uhm, clear, gist, title, localLLM

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .shapes: return "Shapes"
        case .voz: return "Voz"
        case .diarizer: return "Speaker labels"
        case .uhm: return "Uhm"
        case .clear: return "Clear"
        case .gist: return "Gist"
        case .title: return "Title"
        case .localLLM: return "Local language model"
        }
    }

    public var purpose: String {
        switch self {
        case .shapes: return "Turns hand-drawn rectangles, circles, triangles, stars, and lines into clean shapes."
        case .voz: return "High-accuracy transcription for recordings in 25 languages, about 300 times faster than real time."
        case .diarizer: return "Works out who is speaking when, so you can label and hide speakers."
        case .uhm: return "Finds um, uh, and hmm in recordings so playback can skip them."
        case .clear: return "Removes background noise and echo from lecture recordings."
        case .gist: return "Suggests topic tags for notes, used for organization and search."
        case .title: return "Suggests a short title and description for untitled notes and recordings."
        case .localLLM: return "A small Hugging Face model for summaries and questions without the internet. Loads only while it works."
        }
    }

    public var vendor: String {
        switch self {
        case .diarizer: return "FluidAudio (pyannote community-1)"
        case .localLLM: return "Hugging Face via MLX"
        default: return "Desert Ant Labs"
        }
    }

    public var approximateSize: String {
        switch self {
        case .shapes: return "0.2 MB"
        case .voz: return "467 MB"
        case .diarizer: return "About 30 MB"
        case .uhm: return "45 MB"
        case .clear: return "9 MB"
        case .gist: return "15 MB"
        case .title: return "About 280 MB"
        case .localLLM: return "Depends on the model"
        }
    }

    /// Small models download quietly the first time a feature needs them.
    public var downloadsAutomatically: Bool {
        switch self {
        case .shapes, .clear, .gist: return true
        default: return false
        }
    }

    public var systemImage: String {
        switch self {
        case .shapes: return "square.on.circle"
        case .voz: return "waveform"
        case .diarizer: return "person.2.wave.2"
        case .uhm: return "scissors"
        case .clear: return "wand.and.stars"
        case .gist: return "tag"
        case .title: return "textformat"
        case .localLLM: return "cpu"
        }
    }

    /// Hugging Face repository the weights come from.
    var desertAntRepo: String? {
        switch self {
        case .diarizer, .localLLM: return nil
        default: return "desert-ant-labs/\(rawValue)"
        }
    }
}

public enum ModelStatus: Equatable, Sendable {
    case notDownloaded
    case downloading(Double)
    case ready
    case failed(String)
    case unavailable(String)

    public var isReady: Bool { self == .ready }
}

/// Small open models offered for on-device summaries. Any MLX repo id also works.
public struct LocalModelPreset: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let size: String
    public let note: String

    public static let all: [LocalModelPreset] = [
        LocalModelPreset(id: "mlx-community/Qwen3.5-0.8B-4bit", name: "Qwen 3.5 0.8B", size: "~0.6 GB", note: "Smallest useful option; fast on any recent iPhone or iPad."),
        LocalModelPreset(id: "mlx-community/Qwen3-0.6B-4bit", name: "Qwen 3 0.6B", size: "~0.35 GB", note: "Tiny and quick; good for titles and short summaries."),
        LocalModelPreset(id: "mlx-community/gemma-3-1b-it-qat-4bit", name: "Gemma 3 1B", size: "~0.75 GB", note: "Strong writing quality for its size."),
        LocalModelPreset(id: "mlx-community/LFM2.5-1.2B-Instruct-4bit", name: "LFM 2.5 1.2B", size: "~0.7 GB", note: "Dense and fast; built for on-device use."),
        LocalModelPreset(id: "mlx-community/Qwen3.5-2B-4bit", name: "Qwen 3.5 2B", size: "~1.3 GB", note: "Best summaries here; needs a device with 8 GB of memory."),
    ]
}

/// Tracks, downloads, and deletes on-device models.
@MainActor
@Observable
public final class ModelManager {
    public static let shared = ModelManager()

    public private(set) var statuses: [OnDeviceModel: ModelStatus] = [:]
    private var tasks: [OnDeviceModel: Task<Void, Never>] = [:]

    /// The Hugging Face repo used for `.localLLM`.
    public var localModelID: String {
        didSet { UserDefaults.standard.set(localModelID, forKey: "localModelID"); refresh() }
    }

    private init() {
        localModelID = UserDefaults.standard.string(forKey: "localModelID") ?? LocalModelPreset.all[0].id
        refresh()
    }

    public func status(_ model: OnDeviceModel) -> ModelStatus {
        statuses[model] ?? .notDownloaded
    }

    public func refresh() {
        for model in OnDeviceModel.allCases {
            if case .downloading = statuses[model] { continue }
            statuses[model] = isOnDisk(model) ? .ready : .notDownloaded
        }
        #if targetEnvironment(simulator)
        // MLX needs a real GPU; the simulator cannot run it.
        statuses[.localLLM] = .unavailable("Runs on a real iPhone or iPad only.")
        statuses[.title] = .unavailable("Runs on a real iPhone or iPad only.")
        #endif
    }

    func isOnDisk(_ model: OnDeviceModel) -> Bool {
        switch model {
        case .shapes: return Shapes().isDownloaded()
        case .voz: return Voz.isDownloaded()
        case .clear: return Clear().isDownloaded()
        case .uhm: return Uhm().isDownloaded()
        case .gist: return Gist(variant: .english).isDownloaded()
        case .title: return FileManager.default.fileExists(atPath: Self.titleDirectory.appendingPathComponent("config.json").path)
        case .diarizer: return Self.directoryHasFiles(Self.diarizerDirectory)
        case .localLLM: return FileManager.default.fileExists(atPath: Self.localModelDirectory(localModelID).appendingPathComponent("config.json").path)
        }
    }

    public func download(_ model: OnDeviceModel) {
        guard tasks[model] == nil, status(model) != .ready else { return }
        if case .unavailable = status(model) { return }
        statuses[model] = .downloading(0)
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                guard let self, case .downloading = self.statuses[model] else { return }
                self.statuses[model] = .downloading(fraction)
            }
        }
        let localID = localModelID
        tasks[model] = Task { [weak self] in
            do {
                try await Self.performDownload(model, localModelID: localID, progress: report)
                self?.statuses[model] = .ready
            } catch is CancellationError {
                self?.statuses[model] = .notDownloaded
            } catch {
                self?.statuses[model] = .failed(error.localizedDescription)
            }
            self?.tasks[model] = nil
        }
    }

    public func cancel(_ model: OnDeviceModel) {
        tasks[model]?.cancel()
        tasks[model] = nil
        statuses[model] = .notDownloaded
    }

    public func delete(_ model: OnDeviceModel) {
        cancel(model)
        for url in Self.storageLocations(for: model, localModelID: localModelID) {
            try? FileManager.default.removeItem(at: url)
        }
        refresh()
    }

    /// Bytes on disk for a model, for the settings screen.
    public func diskUsage(_ model: OnDeviceModel) -> Int64 {
        Self.storageLocations(for: model, localModelID: localModelID).reduce(0) { $0 + ModelStorage.size(of: $1) }
    }

    /// Downloads a model if it is small and missing, for features that want it quietly.
    public func ensureSmallModel(_ model: OnDeviceModel) {
        if model.downloadsAutomatically, status(model) == .notDownloaded { download(model) }
    }

    // MARK: Storage

    nonisolated static func desertAntCache(for model: OnDeviceModel) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("desert-ant-models/desert-ant-labs/\(model.rawValue)", isDirectory: true)
    }

    nonisolated static var titleDirectory: URL { ModelStorage.directory("title") }
    nonisolated static var diarizerDirectory: URL { ModelStorage.directory("diarizer") }

    nonisolated static func localModelDirectory(_ repo: String) -> URL {
        ModelStorage.directory("llm").appendingPathComponent(repo.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
    }

    nonisolated static func storageLocations(for model: OnDeviceModel, localModelID: String) -> [URL] {
        switch model {
        case .title: return [titleDirectory]
        case .diarizer: return [diarizerDirectory]
        case .localLLM: return [localModelDirectory(localModelID)]
        default: return [desertAntCache(for: model)]
        }
    }

    nonisolated static func directoryHasFiles(_ url: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return false }
        return enumerator.nextObject() != nil
    }

    nonisolated static func performDownload(_ model: OnDeviceModel, localModelID: String, progress: @Sendable @escaping (Double) -> Void) async throws {
        switch model {
        case .shapes: try await Shapes().download(progress: progress)
        case .clear: try await Clear().download(progress: progress)
        case .uhm: try await Uhm().download(progress: progress)
        case .gist: try await Gist(variant: .english).download(progress: progress)
        case .voz: _ = try await Voz.download(progress: { progress($0.fraction) })
        case .title:
            let files = TitleModel.files.values.first ?? []
            try await HuggingFaceDownloader().download(repo: TitleModel.repo, revision: TitleModel.revision, files: files, to: titleDirectory, progress: progress)
        case .diarizer:
            let manager = OfflineDiarizerManager(config: .default)
            progress(0.1)
            try await manager.prepareModels(directory: diarizerDirectory)
        case .localLLM:
            try await HuggingFaceDownloader().download(repo: localModelID, to: localModelDirectory(localModelID), progress: progress)
        }
        progress(1)
    }
}
