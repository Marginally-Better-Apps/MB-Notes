import CryptoKit
import Foundation

/// Where downloaded model weights live. Everything sits under Application Support
/// so it survives launches, is excluded from iCloud backup, and can be deleted per model.
public enum ModelStorage {
    public static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Models", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = url
            try? mutable.setResourceValues(values)
        }
        return url
    }

    public static func directory(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static func size(of url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}

/// Downloads a Hugging Face model repository snapshot into a local folder, with byte-level
/// progress and checksums. A `.complete` marker is written last, so a cancelled or crashed
/// download never looks finished.
public struct HuggingFaceDownloader: Sendable {
    public enum DownloadError: LocalizedError {
        case badRepository(String)
        case http(Int, String)
        case noFiles(String)
        case corrupt(String)

        public var errorDescription: String? {
            switch self {
            case .badRepository(let id): return "\(id) is not a Hugging Face model id (expected owner/name)."
            case .http(let code, let file): return "Hugging Face returned HTTP \(code) for \(file)."
            case .noFiles(let id): return "\(id) has no MLX weights to download."
            case .corrupt(let file): return "\(file) didn't download correctly. Try again."
            }
        }
    }

    public struct Entry: Sendable {
        public let path: String
        public let size: Int64?
        /// SHA-256 for large files stored with Git LFS.
        public let sha256: String?
    }

    /// File patterns an MLX language model needs.
    public static let mlxPatterns = [".json", ".safetensors", ".jinja", ".model", ".txt", ".tiktoken"]
    static let markerName = ".complete"

    public var endpoint = URL(string: "https://huggingface.co")!

    public init() {}

    /// Whether a previous download finished, including its checksums.
    public static func isComplete(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(markerName).path)
    }

    /// Lists the repository's files.
    public func files(repo: String, revision: String = "main") async throws -> [Entry] {
        guard repo.split(separator: "/").count == 2 else { throw DownloadError.badRepository(repo) }
        let url = endpoint.appendingPathComponent("api/models/\(repo)/tree/\(revision)")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw DownloadError.http(http.statusCode, repo) }
        struct LFS: Decodable { let oid: String? }
        struct Raw: Decodable { let type: String; let path: String; let size: Int64?; let lfs: LFS? }
        return try JSONDecoder().decode([Raw].self, from: data).filter { $0.type == "file" }.map { Entry(path: $0.path, size: $0.size, sha256: $0.lfs?.oid) }
    }

    /// Downloads matching files into `destination`, skipping files already present and verified.
    public func download(
        repo: String,
        revision: String = "main",
        files explicit: [String]? = nil,
        patterns: [String] = HuggingFaceDownloader.mlxPatterns,
        to destination: URL,
        progress: @Sendable @escaping (_ received: Int64, _ total: Int64?) -> Void = { _, _ in }
    ) async throws {
        let listing = try await files(repo: repo, revision: revision)
        let wanted = listing.filter { entry in
            if let explicit { return explicit.contains(entry.path) }
            return patterns.contains { entry.path.hasSuffix($0) }
        }
        guard !wanted.isEmpty else { throw DownloadError.noFiles(repo) }
        let knownTotal = wanted.allSatisfy { $0.size != nil } ? wanted.reduce(Int64(0)) { $0 + ($1.size ?? 0) } : nil
        var completed: Int64 = 0
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination.appendingPathComponent(Self.markerName))
        for entry in wanted {
            try Task.checkCancellation()
            let target = destination.appendingPathComponent(entry.path)
            if Self.verify(target, entry: entry) {
                completed += entry.size ?? 0
                progress(completed, knownTotal)
                continue
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let remote = endpoint.appendingPathComponent("\(repo)/resolve/\(revision)/\(entry.path)")
            let base = completed
            let temporary = try await ProgressDownload.run(remote) { written in
                progress(base + written, knownTotal)
            }
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: temporary, to: target)
            guard Self.verify(target, entry: entry) else {
                try? FileManager.default.removeItem(at: target)
                throw DownloadError.corrupt(entry.path)
            }
            completed += entry.size ?? 0
            progress(completed, knownTotal)
        }
        try Data().write(to: destination.appendingPathComponent(Self.markerName))
    }

    /// A file is good when its size matches and, for LFS files, its SHA-256 matches.
    static func verify(_ url: URL, entry: Entry) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), let size = attributes[.size] as? Int64 else { return false }
        if let expected = entry.size, expected != size { return false }
        guard let expected = entry.sha256 else { return true }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined() == expected.lowercased()
    }
}

/// A download task whose `didWriteData` delegate callbacks actually fire. The async
/// `URLSession.download(from:delegate:)` never delivers byte progress, so this uses a
/// session-level delegate and bridges completion to a continuation.
private final class ProgressDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession!

    private init(onProgress: @escaping @Sendable (Int64) -> Void) {
        self.onProgress = onProgress
    }

    static func run(_ url: URL, onProgress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let delegate = ProgressDownload(onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        delegate.session = session
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file is deleted when this returns, so move it somewhere stable first.
        let stable = FileManager.default.temporaryDirectory.appendingPathComponent("hf-\(UUID().uuidString)")
        do {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                throw HuggingFaceDownloader.DownloadError.http(http.statusCode, downloadTask.originalRequest?.url?.lastPathComponent ?? "")
            }
            try FileManager.default.moveItem(at: location, to: stable)
            continuation?.resume(returning: stable)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, let continuation {
            continuation.resume(throwing: error)
            self.continuation = nil
        }
        session.finishTasksAndInvalidate()
    }
}
