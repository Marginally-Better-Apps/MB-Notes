import Foundation
import ZIPFoundation

/// File access for one `.mbnote` package. See `NoteManifest` for the layout.
public struct NotePackage: Hashable, Sendable {
    public static let fileExtension = "mbnote"
    /// A zipped note for Mail, Messages, and anything else that cannot attach a folder.
    public static let archiveExtension = "mbnotes"
    public static let manifestName = "document.json"
    public static let thumbnailName = "thumbnail.png"

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    // MARK: Creating and opening

    public static func create(at url: URL, manifest: NoteManifest) throws -> NotePackage {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        for folder in ["ink", "recognition", "media", "sources", "recordings"] {
            try fm.createDirectory(at: url.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true)
        }
        let package = NotePackage(url: url)
        try package.writeManifest(manifest)
        return package
    }

    public func readManifest() throws -> NoteManifest {
        let data = try Data(contentsOf: url.appendingPathComponent(Self.manifestName))
        return try NoteJSON.decoder.decode(NoteManifest.self, from: data)
    }

    public func writeManifest(_ manifest: NoteManifest) throws {
        let data = try NoteJSON.encoder.encode(manifest)
        try data.write(to: url.appendingPathComponent(Self.manifestName), options: .atomic)
    }

    // MARK: Files inside the package

    /// Resolves a package-relative path, refusing anything that escapes the package.
    ///
    /// Checks path components rather than comparing standardized paths: on device the
    /// container lives under `/private/var` (a symlink to `/var`), and `standardizedFileURL`
    /// only strips `/private` from paths that already exist, so new files would be refused.
    public func fileURL(_ relativePath: String) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        return url.appendingPathComponent(relativePath)
    }

    public func inkURL(for pageID: UUID) -> URL {
        url.appendingPathComponent("ink/\(pageID.uuidString).drawing")
    }

    public func readInk(for pageID: UUID) -> Data? {
        try? Data(contentsOf: inkURL(for: pageID))
    }

    public func writeInk(_ data: Data, for pageID: UUID) throws {
        try ensureDirectory("ink")
        if data.isEmpty {
            try? FileManager.default.removeItem(at: inkURL(for: pageID))
        } else {
            try data.write(to: inkURL(for: pageID), options: .atomic)
        }
    }

    public func readRecognition(for pageID: UUID) -> PageRecognition? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("recognition/\(pageID.uuidString).json")) else { return nil }
        return try? NoteJSON.decoder.decode(PageRecognition.self, from: data)
    }

    public func writeRecognition(_ recognition: PageRecognition, for pageID: UUID) throws {
        try ensureDirectory("recognition")
        try NoteJSON.encoder.encode(recognition).write(to: url.appendingPathComponent("recognition/\(pageID.uuidString).json"), options: .atomic)
    }

    public func readTranscript(_ recording: RecordingSummary) -> Transcript? {
        guard let file = fileURL(recording.transcriptPath), let data = try? Data(contentsOf: file) else { return nil }
        return try? NoteJSON.decoder.decode(Transcript.self, from: data)
    }

    public func writeTranscript(_ transcript: Transcript, for recording: RecordingSummary) throws {
        try ensureDirectory("recordings")
        guard let file = fileURL(recording.transcriptPath) else { return }
        try NoteJSON.encoder.encode(transcript).write(to: file, options: .atomic)
    }

    /// Copies a file into `folder`, returning its package-relative path.
    public func importFile(_ source: URL, into folder: String, preferredName: String? = nil) throws -> String {
        try ensureDirectory(folder)
        let ext = source.pathExtension.isEmpty ? "bin" : source.pathExtension.lowercased()
        let name = "\(preferredName ?? UUID().uuidString).\(ext)"
        let destination = url.appendingPathComponent(folder).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.copyItem(at: source, to: destination)
        return "\(folder)/\(name)"
    }

    /// Writes data into `folder`, returning its package-relative path.
    public func addData(_ data: Data, into folder: String, fileExtension: String) throws -> String {
        try ensureDirectory(folder)
        let relative = "\(folder)/\(UUID().uuidString).\(fileExtension)"
        try data.write(to: url.appendingPathComponent(relative), options: .atomic)
        return relative
    }

    public func removePageFiles(_ pageID: UUID) {
        try? FileManager.default.removeItem(at: inkURL(for: pageID))
        try? FileManager.default.removeItem(at: url.appendingPathComponent("recognition/\(pageID.uuidString).json"))
    }

    // MARK: Archives

    /// Zips the package into the temporary directory. Audio is stored uncompressed since it already is.
    public func exportArchive(includeRecordings: Bool = true) throws -> URL {
        let name = url.deletingPathExtension().lastPathComponent
        let archiveURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).\(Self.archiveExtension)")
        try? FileManager.default.removeItem(at: archiveURL)
        let archive = try Archive(url: archiveURL, accessMode: .create, pathEncoding: nil)
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else { return archiveURL }
        let base = url.standardizedFileURL.path
        for case let file as URL in enumerator {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let relative = String(file.standardizedFileURL.path.dropFirst(base.count + 1))
            if !includeRecordings, relative.hasPrefix("recordings/") { continue }
            let method: CompressionMethod = file.pathExtension == "m4a" ? .none : .deflate
            try archive.addEntry(with: "\(name).\(Self.fileExtension)/\(relative)", fileURL: file, compressionMethod: method)
        }
        return archiveURL
    }

    /// Unzips an archive made by `exportArchive` into `folder` and returns the new package.
    public static func importArchive(_ archiveURL: URL, into folder: URL) throws -> NotePackage {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("note-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.unzipItem(at: archiveURL, to: staging, allowUncontainedSymlinks: false)
        let children = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
        guard let root = children.first(where: { $0.pathExtension == fileExtension }) ?? children.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent(manifestName).path) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let package = NotePackage(url: root)
        var manifest = try package.readManifest()
        manifest.id = UUID()
        let name = manifest.title.isEmpty ? archiveURL.deletingPathExtension().lastPathComponent : manifest.title
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var destination = folder.appendingPathComponent(safe, isDirectory: true).appendingPathExtension(fileExtension)
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(safe) \(counter)", isDirectory: true).appendingPathExtension(fileExtension)
            counter += 1
        }
        try FileManager.default.moveItem(at: root, to: destination)
        let imported = NotePackage(url: destination)
        try imported.writeManifest(manifest)
        return imported
    }

    public var thumbnailURL: URL { url.appendingPathComponent(Self.thumbnailName) }

    public func writeThumbnail(_ png: Data) throws {
        try png.write(to: thumbnailURL, options: .atomic)
    }

    private func ensureDirectory(_ folder: String) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true)
    }
}
