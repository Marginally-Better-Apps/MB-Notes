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
        case .diarizer: return "Speaker Labels"
        case .uhm: return "Uhm"
        case .clear: return "Clear"
        case .gist: return "Gist"
        case .title: return "Title"
        case .localLLM: return "Local Language Model"
        }
    }

    public var purpose: String {
        switch self {
        case .shapes: return "Recognizes hand-drawn rectangles, circles, triangles, stars, and lines as a backup to the built-in shape fitter."
        case .voz: return "High-accuracy transcription for recordings in 25 languages."
        case .diarizer: return "Works out who is speaking when, so you can label and hide speakers."
        case .uhm: return "Finds um, uh, and hmm in recordings so playback can skip them."
        case .clear: return "Removes background noise and echo from lecture recordings."
        case .gist: return "Suggests topic tags for notes, used for organization and search."
        case .title: return "Suggests a short title and description for untitled notes and recordings."
        case .localLLM: return "Summaries and questions without the internet. Loads only while it works."
        }
    }

    public var vendor: String {
        switch self {
        case .diarizer: return "FluidAudio · pyannote community-1"
        case .localLLM: return "Hugging Face · MLX"
        default: return "Desert Ant Labs"
        }
    }

    /// Rough download size, for the card and for turning fractions into bytes.
    public var approximateBytes: Int64 {
        switch self {
        case .shapes: return 200_000
        case .voz: return 467_000_000
        case .diarizer: return 30_000_000
        case .uhm: return 45_000_000
        case .clear: return 9_000_000
        case .gist: return 15_000_000
        case .title: return 280_000_000
        case .localLLM: return 0
        }
    }

    public var approximateSize: String {
        approximateBytes == 0 ? "Depends on the model" : ByteCountFormatter.string(fromByteCount: approximateBytes, countStyle: .file)
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
        case .clear: return "wand.and.sparkles"
        case .gist: return "tag"
        case .title: return "textformat"
        case .localLLM: return "cpu"
        }
    }

    /// Needs the Neural Engine or Metal, so it cannot run in the simulator.
    var needsDevice: Bool { self == .title || self == .localLLM }
}

/// Where a model is in its life, with enough detail to show what is happening.
public enum ModelPhase: Equatable, Sendable {
    case notDownloaded
    case downloading(received: Int64, total: Int64?, bytesPerSecond: Double?)
    case verifying
    /// Building the runtime (Core ML specialization, MLX loading). Can take tens of seconds with no progress.
    case preparing(String)
    case ready
    case failed(String)
    case unavailable(String)

    public var isReady: Bool { self == .ready }
    public var isBusy: Bool {
        switch self {
        case .downloading, .verifying, .preparing: return true
        default: return false
        }
    }
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

/// Tracks, downloads, enables, and deletes on-device models.
@MainActor
@Observable
public final class ModelManager {
    public static let shared = ModelManager()

    public private(set) var phases: [OnDeviceModel: ModelPhase] = [:]
    /// Per-model enabled flags; a disabled model stays on disk but features skip it.
    private var enabled: [OnDeviceModel: Bool] = [:]
    private var tasks: [OnDeviceModel: Task<Void, Never>] = [:]
    /// Increments per download so a cancelled task cannot overwrite a newer one's phase.
    private var generations: [OnDeviceModel: Int] = [:]
    /// Shared recognizer so the editor and Settings see the same download.
    public let shapes = Shapes()

    /// The Hugging Face repo used for `.localLLM`.
    public var localModelID: String {
        didSet {
            UserDefaults.standard.set(localModelID, forKey: "localModelID")
            refresh()
        }
    }

    private init() {
        localModelID = UserDefaults.standard.string(forKey: "localModelID") ?? LocalModelPreset.all[0].id
        for model in OnDeviceModel.allCases {
            enabled[model] = UserDefaults.standard.object(forKey: "model.enabled.\(model.rawValue)") as? Bool ?? true
            #if targetEnvironment(simulator)
            if model.needsDevice { phases[model] = .unavailable("Runs on a real iPhone or iPad only.") }
            #endif
        }
        refresh()
    }

    public func phase(_ model: OnDeviceModel) -> ModelPhase {
        phases[model] ?? .notDownloaded
    }

    public func isEnabled(_ model: OnDeviceModel) -> Bool {
        enabled[model] ?? true
    }

    /// Downloaded and switched on.
    public func isUsable(_ model: OnDeviceModel) -> Bool {
        isEnabled(model) && phase(model).isReady
    }

    public func setEnabled(_ model: OnDeviceModel, _ value: Bool) {
        enabled[model] = value
        UserDefaults.standard.set(value, forKey: "model.enabled.\(model.rawValue)")
        if !value { cancel(model) }
    }

    /// Re-checks what is on disk, off the main thread since it hashes files.
    public func refresh() {
        let localID = localModelID
        Task.detached(priority: .utility) { [weak self] in
            var present: [OnDeviceModel: Bool] = [:]
            for model in OnDeviceModel.allCases { present[model] = Self.isOnDisk(model, localModelID: localID) }
            await self?.applyRefresh(present)
        }
    }

    private func applyRefresh(_ present: [OnDeviceModel: Bool]) {
        for model in OnDeviceModel.allCases {
            if phase(model).isBusy { continue }
            if case .unavailable = phase(model) { continue }
            phases[model] = present[model] == true ? .ready : .notDownloaded
        }
    }

    nonisolated static func isOnDisk(_ model: OnDeviceModel, localModelID: String) -> Bool {
        switch model {
        case .shapes: return Shapes().isDownloaded()
        case .voz: return Voz.isDownloaded()
        case .clear: return Clear().isDownloaded()
        case .uhm: return Uhm().isDownloaded()
        case .gist: return Gist(variant: .english).isDownloaded()
        case .title: return HuggingFaceDownloader.isComplete(titleDirectory)
        case .diarizer: return directoryHasFiles(diarizerDirectory)
        case .localLLM: return HuggingFaceDownloader.isComplete(localModelDirectory(localModelID))
        }
    }

    // MARK: Downloading

    public func download(_ model: OnDeviceModel) {
        guard tasks[model] == nil, !phase(model).isReady else { return }
        if case .unavailable = phase(model) { return }
        let generation = (generations[model] ?? 0) + 1
        generations[model] = generation
        phases[model] = .downloading(received: 0, total: model.approximateBytes > 0 ? model.approximateBytes : nil, bytesPerSecond: nil)
        let reporter = ProgressReporter(model: model) { [weak self] phase in
            Task { @MainActor in
                guard let self, self.generations[model] == generation, self.phase(model).isBusy else { return }
                self.phases[model] = phase
            }
        }
        let localID = localModelID
        let shapes = shapes
        tasks[model] = Task { [weak self] in
            do {
                try await Self.performDownload(model, localModelID: localID, shapes: shapes, reporter: reporter)
                guard let self, self.generations[model] == generation else { return }
                self.phases[model] = .ready
            } catch {
                guard let self, self.generations[model] == generation else { return }
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    self.phases[model] = .notDownloaded
                } else {
                    self.phases[model] = .failed(error.localizedDescription)
                }
            }
            if self?.generations[model] == generation { self?.tasks[model] = nil }
        }
    }

    public func cancel(_ model: OnDeviceModel) {
        guard let task = tasks[model] else { return }
        task.cancel()
        tasks[model] = nil
        generations[model] = (generations[model] ?? 0) + 1
        if phase(model).isBusy { phases[model] = .notDownloaded }
    }

    public func delete(_ model: OnDeviceModel) {
        cancel(model)
        for url in Self.storageLocations(for: model, localModelID: localModelID) {
            try? FileManager.default.removeItem(at: url)
        }
        phases[model] = .notDownloaded
    }

    /// Bytes on disk for a model, for the settings screen.
    public func diskUsage(_ model: OnDeviceModel) -> Int64 {
        Self.storageLocations(for: model, localModelID: localModelID).reduce(0) { $0 + ModelStorage.size(of: $1) }
    }

    /// Downloads a model if it is small, missing, and switched on.
    public func ensureSmallModel(_ model: OnDeviceModel) {
        guard isEnabled(model), model.downloadsAutomatically, phase(model) == .notDownloaded else { return }
        download(model)
    }

    // MARK: Storage

    nonisolated static var titleDirectory: URL { ModelStorage.directory("title") }
    nonisolated static var diarizerDirectory: URL { ModelStorage.directory("diarizer") }

    nonisolated static func desertAntCache(for model: OnDeviceModel) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("desert-ant-models/desert-ant-labs/\(model.rawValue)", isDirectory: true)
    }

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

    nonisolated static func performDownload(_ model: OnDeviceModel, localModelID: String, shapes: Shapes, reporter: ProgressReporter) async throws {
        switch model {
        case .shapes:
            try await shapes.download(progress: reporter.fraction)
            reporter.preparing("Optimizing for this device…")
        case .clear:
            try await Clear().load { progress in
                switch progress.phase {
                case .downloading: reporter.fraction(progress.fraction)
                case .preparing: reporter.preparing("Optimizing for this device…")
                }
            }
        case .uhm:
            try await Uhm().download(progress: reporter.fraction)
            reporter.preparing("Optimizing for this device…")
        case .gist:
            try await Gist(variant: .english).download(progress: reporter.fraction)
            reporter.preparing("Optimizing for this device…")
        case .voz:
            _ = try await Voz.download { reporter.bytes($0.completedBytes, total: $0.totalBytes) }
            // The first load specializes the model for the Neural Engine, which takes a while.
            reporter.preparing("Optimizing for this device (about 20 seconds, one time)…")
            _ = try await Voz()
        case .title:
            let files = TitleModel.files[.apple] ?? []
            try await HuggingFaceDownloader().download(repo: TitleModel.repo, revision: TitleModel.revision, files: files, to: titleDirectory, progress: reporter.bytes)
        case .diarizer:
            let manager = OfflineDiarizerManager(config: .default)
            reporter.preparing("Downloading speaker models…")
            try await manager.prepareModels(directory: diarizerDirectory)
            reporter.preparing("Compiling speaker models…")
        case .localLLM:
            try await HuggingFaceDownloader().download(repo: localModelID, to: localModelDirectory(localModelID), progress: reporter.bytes)
        }
        try Task.checkCancellation()
    }
}

/// Turns raw progress callbacks into `ModelPhase`s with a throttled rate estimate.
final class ProgressReporter: @unchecked Sendable {
    private let model: OnDeviceModel
    private let send: @Sendable (ModelPhase) -> Void
    private let lock = NSLock()
    private var lastBytes: Int64 = 0
    private var lastTime = Date()
    private var rate: Double?
    private var lastSent = Date.distantPast

    init(model: OnDeviceModel, send: @escaping @Sendable (ModelPhase) -> Void) {
        self.model = model
        self.send = send
    }

    /// A 0...1 fraction from SDKs that do not report bytes. 1 means the bytes are in and
    /// the runtime is being built, which the SDK reports no progress for.
    @Sendable func fraction(_ value: Double) {
        if value >= 1 {
            preparing("Optimizing for this device…")
        } else {
            let total = model.approximateBytes
            bytes(Int64(value * Double(total)), total: total)
        }
    }

    @Sendable func bytes(_ received: Int64, total: Int64?) {
        let now = Date()
        lock.lock()
        let elapsed = now.timeIntervalSince(lastTime)
        if elapsed >= 0.5 {
            let instant = Double(received - lastBytes) / elapsed
            rate = rate.map { $0 * 0.6 + instant * 0.4 } ?? instant
            lastBytes = received
            lastTime = now
        }
        // About four updates a second is plenty for a progress bar.
        let shouldSend = now.timeIntervalSince(lastSent) >= 0.25 || (total != nil && received >= total!)
        if shouldSend { lastSent = now }
        let rate = self.rate
        lock.unlock()
        guard shouldSend else { return }
        send(.downloading(received: received, total: total.flatMap { $0 > 0 ? $0 : nil }, bytesPerSecond: rate.map { max(0, $0) }))
    }

    @Sendable func preparing(_ message: String) {
        send(.preparing(message))
    }
}
