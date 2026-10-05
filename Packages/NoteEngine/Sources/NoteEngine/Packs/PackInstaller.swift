import Foundation
import ZIPFoundation

/// Unpacks and checks a pack before it is installed, so the app can show a preview
/// and ask first. Every way a pack arrives (Files, AirDrop, a link, drag and drop)
/// goes through `stage`, then `PackRegistry.install(_:)`.
public enum PackInstaller {
    /// Limits that keep a hostile or careless pack from filling the device.
    public enum Limits {
        public static let compressedBytes: Int64 = 50 * 1024 * 1024
        public static let unpackedBytes: Int64 = 200 * 1024 * 1024
        public static let fileCount = 2_000
    }

    public enum StageError: LocalizedError, Equatable {
        case tooLarge(String)
        case tooManyFiles(String)
        case containsLinks(String)
        case badIdentifier(String)
        case duplicateItem(String, String)

        public var errorDescription: String? {
            switch self {
            case .tooLarge(let name): return "\(name) is larger than MB Notes allows for a pack."
            case .tooManyFiles(let name): return "\(name) has too many files to be a pack."
            case .containsLinks(let name): return "\(name) contains links to other files, which packs may not use."
            case .badIdentifier(let id): return "“\(id)” is not a valid identifier. Use letters, numbers, dots, and dashes."
            case .duplicateItem(let name, let id): return "\(name) defines “\(id)” more than once."
            }
        }
    }

    /// A checked pack sitting in a temporary folder, ready to install.
    public struct Preview: Identifiable, Sendable {
        public let pack: LoadedPack
        /// The version already installed with the same id, if any.
        public let installed: PackManifest?
        public let unpackedBytes: Int64

        public var id: String { pack.rootURL.path }
        public var isUpdate: Bool { installed != nil }
        public var changesAuthor: Bool { installed.map { $0.author != pack.manifest.author } ?? false }
    }

    /// Whether a URL is worth treating as a pack: a `.mbpack`, or a zip or folder with a `pack.json` inside.
    public static func looksLikePack(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == PackRegistry.packExtension { return true }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            return PackRegistry.findPackRoot(in: url) != nil
        }
        guard ext == "zip", let archive = try? Archive(url: url, accessMode: .read, pathEncoding: nil) else { return false }
        return archive.contains { $0.path.split(separator: "/").count <= 2 && $0.path.hasSuffix("pack.json") }
    }

    /// Unpacks `source` into a temporary folder and validates it. Safe to call off the main thread.
    public static func stage(_ source: URL, registry: PackRegistry) async throws -> Preview {
        try await Task.detached(priority: .userInitiated) {
            try stageSync(source, registry: registry)
        }.value
    }

    static func stageSync(_ source: URL, registry: PackRegistry) throws -> Preview {
        let fm = FileManager.default
        let name = source.lastPathComponent
        let staging = fm.temporaryDirectory.appendingPathComponent("pack-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)

        var isDirectory: ObjCBool = false
        fm.fileExists(atPath: source.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            try fm.copyItem(at: source, to: unpacked)
        } else {
            let size = (try? fm.attributesOfItem(atPath: source.path)[.size] as? Int64) ?? 0
            guard size <= Limits.compressedBytes else { throw StageError.tooLarge(name) }
            let archive = try Archive(url: source, accessMode: .read, pathEncoding: nil)
            var entries = 0
            var total: Int64 = 0
            for entry in archive {
                entries += 1
                total += Int64(entry.uncompressedSize)
                guard entries <= Limits.fileCount else { throw StageError.tooManyFiles(name) }
                guard total <= Limits.unpackedBytes else { throw StageError.tooLarge(name) }
                guard entry.type != .symlink else { throw StageError.containsLinks(name) }
            }
            try fm.unzipItem(at: source, to: unpacked, skipCRC32: false, allowUncontainedSymlinks: false)
        }

        // Walk the unpacked tree: no links, and within limits even when it came as a folder.
        var count = 0
        var bytes: Int64 = 0
        if let enumerator = fm.enumerator(at: unpacked, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey]) {
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey])
                guard values.isSymbolicLink != true else { throw StageError.containsLinks(name) }
                if values.isRegularFile == true {
                    count += 1
                    bytes += Int64(values.fileSize ?? 0)
                }
                guard count <= Limits.fileCount else { throw StageError.tooManyFiles(name) }
                guard bytes <= Limits.unpackedBytes else { throw StageError.tooLarge(name) }
            }
        }

        let root = PackRegistry.findPackRoot(in: unpacked) ?? unpacked
        let pack = try PackRegistry.load(from: root)
        if pack.id == CorePack.id { throw PackError.reservedIdentifier(pack.id) }
        try validateIdentifiers(pack)
        let installed = registry.catalog.pack(pack.id)?.manifest
        return Preview(pack: pack, installed: installed, unpackedBytes: bytes)
    }

    static func validateIdentifiers(_ pack: LoadedPack) throws {
        func check(_ id: String) throws {
            guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }) else {
                throw StageError.badIdentifier(id)
            }
        }
        try check(pack.id)
        func unique(_ ids: [String]) throws {
            var seen = Set<String>()
            for id in ids {
                try check(id)
                guard seen.insert(id).inserted else { throw StageError.duplicateItem(pack.manifest.name, id) }
            }
        }
        try unique(pack.papers.map(\.id))
        try unique(pack.covers.map(\.id))
        try unique(pack.stickers.map(\.id))
    }

    /// Downloads a pack over HTTPS into a temporary file, refusing anything too large.
    public static func fetch(_ remote: URL) async throws -> URL {
        var url = remote
        // GitHub "blob" links point at HTML; the raw link has the file.
        if url.host == "github.com", url.path.contains("/blob/") {
            url = URL(string: url.absoluteString.replacingOccurrences(of: "/blob/", with: "/raw/")) ?? url
        }
        guard url.scheme == "https" else { throw URLError(.unsupportedURL) }
        let (temporary, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw URLError(.badServerResponse) }
        let size = (try? FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? Int64) ?? 0
        guard size <= Limits.compressedBytes else { throw StageError.tooLarge(url.lastPathComponent) }
        let ext = url.pathExtension.lowercased() == "zip" ? "zip" : PackRegistry.packExtension
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("download-\(UUID().uuidString).\(ext)")
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    /// Removes a staged pack that will not be installed.
    public static func discard(_ preview: Preview) {
        try? FileManager.default.removeItem(at: preview.pack.rootURL.deletingLastPathComponent())
    }
}
