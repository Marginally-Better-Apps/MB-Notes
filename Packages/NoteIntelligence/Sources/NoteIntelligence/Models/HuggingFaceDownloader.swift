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

/// Downloads a Hugging Face model repository snapshot into a local folder.
public struct HuggingFaceDownloader: Sendable {
    public enum DownloadError: LocalizedError {
        case badRepository(String)
        case http(Int, String)
        case noFiles(String)

        public var errorDescription: String? {
            switch self {
            case .badRepository(let id): return "\(id) is not a Hugging Face model id (expected owner/name)."
            case .http(let code, let file): return "Hugging Face returned HTTP \(code) for \(file)."
            case .noFiles(let id): return "\(id) has no MLX weights to download."
            }
        }
    }

    /// File patterns an MLX language model needs.
    public static let mlxPatterns = [".json", ".safetensors", ".jinja", ".model", ".txt", ".tiktoken"]

    public var endpoint = URL(string: "https://huggingface.co")!

    public init() {}

    /// Lists the repository's files.
    public func files(repo: String, revision: String = "main") async throws -> [(path: String, size: Int64?)] {
        guard repo.split(separator: "/").count == 2 else { throw DownloadError.badRepository(repo) }
        let url = endpoint.appendingPathComponent("api/models/\(repo)/tree/\(revision)")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw DownloadError.http(http.statusCode, repo) }
        struct Entry: Decodable { let type: String; let path: String; let size: Int64? }
        return try JSONDecoder().decode([Entry].self, from: data).filter { $0.type == "file" }.map { ($0.path, $0.size) }
    }

    /// Downloads matching files into `destination`, skipping files already present at the right size.
    public func download(
        repo: String,
        revision: String = "main",
        files explicit: [String]? = nil,
        patterns: [String] = HuggingFaceDownloader.mlxPatterns,
        to destination: URL,
        progress: @Sendable @escaping (Double) -> Void = { _ in }
    ) async throws {
        let listing = try await files(repo: repo, revision: revision)
        let wanted = listing.filter { entry in
            if let explicit { return explicit.contains(entry.path) }
            return patterns.contains { entry.path.hasSuffix($0) }
        }
        guard !wanted.isEmpty else { throw DownloadError.noFiles(repo) }
        let total = max(1, wanted.reduce(Int64(0)) { $0 + ($1.size ?? 1) })
        var completed: Int64 = 0
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for entry in wanted {
            try Task.checkCancellation()
            let target = destination.appendingPathComponent(entry.path)
            let existing = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? nil
            if let existing, existing == entry.size {
                completed += entry.size ?? 0
                progress(Double(completed) / Double(total))
                continue
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let remote = endpoint.appendingPathComponent("\(repo)/resolve/\(revision)/\(entry.path)")
            let base = completed
            let (temporary, response) = try await URLSession.shared.download(from: remote, delegate: ProgressDelegate { written in
                progress(Double(base + written) / Double(total))
            })
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw DownloadError.http(http.statusCode, entry.path) }
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: temporary, to: target)
            completed += entry.size ?? 0
            progress(Double(completed) / Double(total))
        }
        progress(1)
    }
}

private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: (Int64) -> Void

    init(_ onProgress: @escaping (Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
