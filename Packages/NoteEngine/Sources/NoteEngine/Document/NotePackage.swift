import Foundation

/// File access for one `.mbnote` package. See `NoteManifest` for the layout.
public struct NotePackage: Hashable, Sendable {
    public static let fileExtension = "mbnote"
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
    public func fileURL(_ relativePath: String) -> URL? {
        let resolved = url.appendingPathComponent(relativePath).standardizedFileURL
        guard resolved.path.hasPrefix(url.standardizedFileURL.path + "/") else { return nil }
        return resolved
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

    public var thumbnailURL: URL { url.appendingPathComponent(Self.thumbnailName) }

    public func writeThumbnail(_ png: Data) throws {
        try png.write(to: thumbnailURL, options: .atomic)
    }

    private func ensureDirectory(_ folder: String) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true)
    }
}
