import Foundation
import ZIPFoundation

/// A pack whose `Include` entries have all been read from disk.
public struct LoadedPack: Identifiable, Sendable {
    public let manifest: PackManifest
    public let rootURL: URL
    public let isBuiltIn: Bool
    public let papers: [PaperTemplate]
    public let covers: [CoverDesign]
    public let stickers: [StickerDefinition]
    public let palettes: [Palette]
    public let symbolSets: [SymbolSet]

    public var id: String { manifest.id }

    /// Resolves a pack-relative path, refusing anything that escapes the pack, links included.
    public func assetURL(_ path: String) -> URL? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        let url = rootURL.appendingPathComponent(path)
        let resolved = url.resolvingSymlinksInPath().path
        let root = rootURL.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(root + "/") else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

public enum PackError: LocalizedError, Equatable {
    case missingManifest(String)
    case invalidManifest(String, String)
    case unsupportedFormat(String, String)
    case missingInclude(String, String)
    case reservedIdentifier(String)
    case notAPack(String)

    public var errorDescription: String? {
        switch self {
        case .missingManifest(let name): return "\(name) has no pack.json."
        case .invalidManifest(let name, let reason): return "\(name)'s pack.json could not be read: \(reason)"
        case .unsupportedFormat(let name, let format): return "\(name) uses \(format), which this version of MB Notes cannot read."
        case .missingInclude(let name, let path): return "\(name) refers to \(path), which is not in the pack."
        case .reservedIdentifier(let id): return "\(id) is reserved for the built-in pack."
        case .notAPack(let name): return "\(name) is not an MB Notes pack."
        }
    }
}

/// An immutable snapshot of every installed pack, used to resolve content references.
public struct PackCatalog: Sendable {
    public let packs: [LoadedPack]
    private let byID: [String: LoadedPack]

    public init(packs: [LoadedPack]) {
        self.packs = packs
        var map: [String: LoadedPack] = [:]
        for pack in packs { map[pack.id] = pack }
        self.byID = map
    }

    public static let empty = PackCatalog(packs: [])

    public func pack(_ id: String) -> LoadedPack? { byID[id] }

    public func paper(_ ref: ContentRef) -> PaperTemplate? {
        byID[ref.packID]?.papers.first { $0.id == ref.itemID }
    }

    public func cover(_ ref: ContentRef) -> CoverDesign? {
        byID[ref.packID]?.covers.first { $0.id == ref.itemID }
    }

    public func sticker(_ ref: ContentRef) -> StickerDefinition? {
        if ref.packID == EmojiPack.id { return EmojiPack.sticker(ref.itemID) }
        return byID[ref.packID]?.stickers.first { $0.id == ref.itemID }
    }

    /// The template a page should draw, preferring installed packs, then the note's
    /// embedded snapshot, then plain white paper.
    public func resolvePaper(_ ref: ContentRef, embedded: EmbeddedResources? = nil) -> PaperTemplate {
        paper(ref) ?? embedded?.papers[ref.rawValue] ?? PaperTemplate(id: "blank", name: "Blank")
    }

    public func resolveCover(_ ref: ContentRef, embedded: EmbeddedResources? = nil) -> CoverDesign {
        cover(ref) ?? embedded?.covers[ref.rawValue] ?? CoverDesign(id: "plain", name: "Plain")
    }

    public func resolveSticker(_ ref: ContentRef, embedded: EmbeddedResources? = nil) -> StickerDefinition? {
        sticker(ref) ?? embedded?.stickers[ref.rawValue]
    }

    public func assetURL(packID: String, path: String) -> URL? {
        byID[packID]?.assetURL(path)
    }

    public var allPapers: [(ref: ContentRef, paper: PaperTemplate)] {
        packs.flatMap { pack in pack.papers.map { (ContentRef(packID: pack.id, itemID: $0.id), $0) } }
    }

    public var allCovers: [(ref: ContentRef, cover: CoverDesign)] {
        packs.flatMap { pack in pack.covers.map { (ContentRef(packID: pack.id, itemID: $0.id), $0) } }
    }

    public var allStickers: [(ref: ContentRef, sticker: StickerDefinition)] {
        packs.flatMap { pack in pack.stickers.map { (ContentRef(packID: pack.id, itemID: $0.id), $0) } }
    }

    public var allPalettes: [Palette] { packs.flatMap(\.palettes) }
    public var allSymbolSets: [SymbolSet] { packs.flatMap(\.symbolSets) }
}

/// The virtual pack every emoji belongs to, so any emoji can be a sticker. Only the
/// character is stored; the device's emoji font draws it.
public enum EmojiPack {
    public static let id = "mbnotes.emoji"

    public static func sticker(_ emoji: String) -> StickerDefinition? {
        guard !emoji.isEmpty, emoji.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.properties.isEmojiModifierBase || $0.value == 0xFE0F }) || emoji.unicodeScalars.first?.properties.isEmoji == true else { return nil }
        return StickerDefinition(id: emoji, name: emoji, category: "Emoji", emoji: emoji, outlined: false)
    }
}

/// Loads packs from the app bundle and the user's pack folder, and installs new ones.
public final class PackRegistry: @unchecked Sendable {
    public static let packExtension = "mbpack"
    public static let engineVersion = "1.0"

    public let builtInDirectory: URL?
    public let userDirectory: URL
    private let lock = NSLock()
    private var _catalog = PackCatalog.empty
    private var _errors: [String: PackError] = [:]

    public init(builtInDirectory: URL?, userDirectory: URL) {
        self.builtInDirectory = builtInDirectory
        self.userDirectory = userDirectory
    }

    public var catalog: PackCatalog { lock.withLock { _catalog } }
    /// Load problems by pack folder name, for display in the pack manager.
    public var loadErrors: [String: PackError] { lock.withLock { _errors } }

    @discardableResult
    public func reload() -> PackCatalog {
        var packs: [LoadedPack] = []
        var errors: [String: PackError] = [:]
        let fm = FileManager.default
        try? fm.createDirectory(at: userDirectory, withIntermediateDirectories: true)

        for (directory, builtIn) in [(builtInDirectory, true), (Optional(userDirectory), false)] {
            guard let directory, let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == Self.packExtension {
                do {
                    let pack = try Self.load(from: url, builtIn: builtIn)
                    if !builtIn, pack.id == CorePack.id || pack.id == EmojiPack.id { throw PackError.reservedIdentifier(pack.id) }
                    packs.removeAll { $0.id == pack.id }
                    packs.append(pack)
                } catch let error as PackError {
                    errors[url.lastPathComponent] = error
                } catch {
                    errors[url.lastPathComponent] = .invalidManifest(url.lastPathComponent, error.localizedDescription)
                }
            }
        }
        // Built-in content first, then community packs alphabetically.
        packs.sort { lhs, rhs in
            if lhs.isBuiltIn != rhs.isBuiltIn { return lhs.isBuiltIn }
            return lhs.manifest.name.localizedCaseInsensitiveCompare(rhs.manifest.name) == .orderedAscending
        }
        let catalog = PackCatalog(packs: packs)
        lock.withLock {
            _catalog = catalog
            _errors = errors
        }
        return catalog
    }

    /// Reads and validates a pack directory.
    public static func load(from url: URL, builtIn: Bool = false) throws -> LoadedPack {
        let name = url.lastPathComponent
        let manifestURL = url.appendingPathComponent("pack.json")
        guard let data = try? Data(contentsOf: manifestURL) else { throw PackError.missingManifest(name) }
        let manifest: PackManifest
        do {
            manifest = try NoteJSON.decoder.decode(PackManifest.self, from: data)
        } catch {
            throw PackError.invalidManifest(name, describe(error))
        }
        guard manifest.format.hasPrefix("mbnotes.pack/1") else { throw PackError.unsupportedFormat(name, manifest.format) }

        // An included file holds one item or an array of items.
        func resolve<T: Codable & Sendable>(_ items: [Include<T>]) throws -> [T] {
            try items.flatMap { item -> [T] in
                switch item {
                case .inline(let value):
                    return [value]
                case .file(let path):
                    let fileURL = url.appendingPathComponent(path).standardizedFileURL
                    guard fileURL.path.hasPrefix(url.standardizedFileURL.path + "/"), let fileData = try? Data(contentsOf: fileURL) else {
                        throw PackError.missingInclude(name, path)
                    }
                    do {
                        if let list = try? NoteJSON.decoder.decode([T].self, from: fileData) { return list }
                        return [try NoteJSON.decoder.decode(T.self, from: fileData)]
                    } catch {
                        throw PackError.invalidManifest(name, "\(path): \(describe(error))")
                    }
                }
            }
        }

        return LoadedPack(
            manifest: manifest,
            rootURL: url,
            isBuiltIn: builtIn,
            papers: try resolve(manifest.papers),
            covers: try resolve(manifest.covers),
            stickers: try resolve(manifest.stickers),
            palettes: try resolve(manifest.palettes),
            symbolSets: try resolve(manifest.symbolSets)
        )
    }

    /// Checks and installs a pack from a `.mbpack` directory or zip archive in one step.
    @discardableResult
    public func install(from source: URL) throws -> LoadedPack {
        try install(try PackInstaller.stageSync(source, registry: self))
    }

    /// Moves a staged pack into place, keeping the previous version until the new one is in.
    @discardableResult
    public func install(_ preview: PackInstaller.Preview) throws -> LoadedPack {
        let fm = FileManager.default
        let root = preview.pack.rootURL
        defer { try? fm.removeItem(at: root.deletingLastPathComponent()) }
        try fm.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        let destination = userDirectory.appendingPathComponent(Self.folderName(for: preview.pack.id))
        let backup = destination.appendingPathExtension("previous")
        try? fm.removeItem(at: backup)
        if fm.fileExists(atPath: destination.path) { try fm.moveItem(at: destination, to: backup) }
        do {
            try fm.moveItem(at: root, to: destination)
        } catch {
            if fm.fileExists(atPath: backup.path) { try? fm.moveItem(at: backup, to: destination) }
            throw error
        }
        try? fm.removeItem(at: backup)
        reload()
        return try Self.load(from: destination)
    }

    public func remove(packID: String) throws {
        guard let pack = catalog.pack(packID), !pack.isBuiltIn else { return }
        try FileManager.default.removeItem(at: pack.rootURL)
        reload()
    }

    /// Zips a pack so it can be shared, returning the archive's URL in the temporary directory.
    public func exportArchive(packID: String) throws -> URL {
        guard let pack = catalog.pack(packID) else { throw PackError.notAPack(packID) }
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent(Self.folderName(for: pack.id))
        try? FileManager.default.removeItem(at: archive)
        try FileManager.default.zipItem(at: pack.rootURL, to: archive, shouldKeepParent: false)
        return archive
    }

    static func folderName(for id: String) -> String {
        let safe = id.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "-" }
        return String(safe) + "." + packExtension
    }

    static func findPackRoot(in directory: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.appendingPathComponent("pack.json").path) { return directory }
        let children = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return children.first { fm.fileExists(atPath: $0.appendingPathComponent("pack.json").path) }
    }

    static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        switch decoding {
        case .keyNotFound(let key, let context):
            return "missing \"\(key.stringValue)\" at \(path(context.codingPath))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return "\(context.debugDescription) at \(path(context.codingPath))"
        @unknown default:
            return error.localizedDescription
        }
    }

    private static func path(_ keys: [CodingKey]) -> String {
        keys.isEmpty ? "the top level" : keys.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
    }
}
