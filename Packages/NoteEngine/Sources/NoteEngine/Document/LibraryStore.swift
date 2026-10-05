import Foundation

/// A folder or note in the library, as shown in a grid.
public struct LibraryEntry: Identifiable, Hashable, Sendable {
    public enum Content: Hashable, Sendable {
        case folder(FolderMetadata)
        case note(NoteManifest)
    }

    public let url: URL
    public let content: Content
    public let modifiedAt: Date
    /// Notes and folders directly inside a folder; nil for notes.
    public var itemCount: Int?

    public var id: URL { url }

    public var name: String {
        switch content {
        case .folder: return url.lastPathComponent
        case .note(let manifest): return manifest.title.isEmpty ? url.deletingPathExtension().lastPathComponent : manifest.title
        }
    }

    public var isFolder: Bool {
        if case .folder = content { return true }
        return false
    }

    public var manifest: NoteManifest? {
        if case .note(let manifest) = content { return manifest }
        return nil
    }

    public var folder: FolderMetadata? {
        if case .folder(let metadata) = content { return metadata }
        return nil
    }

    /// Pinned notes sit at the top of their folder.
    public var isPinned: Bool {
        if case .bool(true) = manifest?.extensions[NoteManifest.pinnedKey] { return true }
        return false
    }
}

public extension NoteManifest {
    /// `extensions` key that marks a note as pinned.
    static let pinnedKey = "mbnotes.pinned"
}

/// Where a trashed item came from and when it was deleted.
public struct DeletionInfo: Codable, Hashable, Sendable {
    /// Folder path relative to the library root; empty for the root itself.
    public var originalFolder: String
    public var deletedAt: Date

    public init(originalFolder: String, deletedAt: Date) {
        self.originalFolder = originalFolder
        self.deletedAt = deletedAt
    }
}

public enum LibrarySort: String, CaseIterable, Sendable {
    case modified, name, created
}

/// The library is plain directories on disk, so it stays browsable in the Files app.
/// Folders are directories with an optional `.folder.json`; notes are `.mbnote` packages.
/// Deleted items move to a hidden `.Trash` folder, with their original location in
/// `.Trash/.index.json`, until they are restored, emptied, or 30 days pass.
public final class LibraryStore: @unchecked Sendable {
    public static let trashName = ".Trash"
    static let trashIndexName = ".index.json"

    public let root: URL
    private let fm = FileManager.default

    public init(root: URL) {
        self.root = root
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public var trash: URL { root.appendingPathComponent(Self.trashName, isDirectory: true) }

    // MARK: Reading

    public func contents(of folder: URL, sort: LibrarySort = .modified) -> [LibraryEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let urls = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        let items = urls.compactMap(item(at:))
        return items.sorted { lhs, rhs in
            if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
            switch sort {
            case .name: return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .created:
                return (lhs.manifest?.createdAt ?? lhs.folder?.createdAt ?? .distantPast) > (rhs.manifest?.createdAt ?? rhs.folder?.createdAt ?? .distantPast)
            case .modified: return lhs.modifiedAt > rhs.modifiedAt
            }
        }
    }

    public func item(at url: URL) -> LibraryEntry? {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        if url.pathExtension == NotePackage.fileExtension {
            guard let manifest = try? NotePackage(url: url).readManifest() else { return nil }
            return LibraryEntry(url: url, content: .note(manifest), modifiedAt: manifest.modifiedAt)
        }
        let metadata = folderMetadata(at: url)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? metadata.createdAt
        let children = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let count = children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.count
        return LibraryEntry(url: url, content: .folder(metadata), modifiedAt: modified, itemCount: count)
    }

    public func folderMetadata(at url: URL) -> FolderMetadata {
        let file = url.appendingPathComponent(FolderMetadata.fileName)
        if let data = try? Data(contentsOf: file), let metadata = try? NoteJSON.decoder.decode(FolderMetadata.self, from: data) {
            return metadata
        }
        return FolderMetadata(color: "#8056F6", symbol: "folder.fill")
    }

    /// Every note in the library, newest first, excluding the trash.
    public func allNotes() -> [LibraryEntry] {
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var notes: [LibraryEntry] = []
        for case let url as URL in enumerator where url.pathExtension == NotePackage.fileExtension {
            enumerator.skipDescendants()
            if let item = item(at: url) { notes.append(item) }
        }
        return notes.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Every folder in the library, for move destinations.
    public func allFolders() -> [URL] {
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [root] }
        var folders = [root]
        for case let url as URL in enumerator {
            if url.pathExtension == NotePackage.fileExtension {
                enumerator.skipDescendants()
                continue
            }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { folders.append(url) }
        }
        return folders
    }

    // MARK: Writing

    @discardableResult
    public func createFolder(named name: String, in parent: URL, metadata: FolderMetadata) throws -> URL {
        let url = uniqueURL(named: sanitized(name, fallback: "New Folder"), extension: nil, in: parent)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try writeFolderMetadata(metadata, at: url)
        return url
    }

    public func writeFolderMetadata(_ metadata: FolderMetadata, at url: URL) throws {
        try NoteJSON.encoder.encode(metadata).write(to: url.appendingPathComponent(FolderMetadata.fileName), options: .atomic)
    }

    @discardableResult
    public func createNote(_ manifest: NoteManifest, in folder: URL) throws -> NotePackage {
        let url = uniqueURL(named: sanitized(manifest.title, fallback: "Untitled"), extension: NotePackage.fileExtension, in: folder)
        return try NotePackage.create(at: url, manifest: manifest)
    }

    /// Renames a folder's directory, or a note's title and package directory.
    @discardableResult
    public func rename(_ url: URL, to name: String) throws -> URL {
        let isNote = url.pathExtension == NotePackage.fileExtension
        let clean = sanitized(name, fallback: isNote ? "Untitled" : "New Folder")
        if isNote {
            let package = NotePackage(url: url)
            var manifest = try package.readManifest()
            manifest.title = name
            manifest.modifiedAt = Date()
            try package.writeManifest(manifest)
        }
        let current = isNote ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
        guard current != clean else { return url }
        let destination = uniqueURL(named: clean, extension: isNote ? NotePackage.fileExtension : nil, in: url.deletingLastPathComponent())
        try fm.moveItem(at: url, to: destination)
        return destination
    }

    @discardableResult
    public func move(_ url: URL, to folder: URL) throws -> URL {
        guard !folder.standardizedFileURL.path.hasPrefix(url.standardizedFileURL.path + "/"), folder != url else { return url }
        let isNote = url.pathExtension == NotePackage.fileExtension
        let name = isNote ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
        let destination = uniqueURL(named: name, extension: isNote ? NotePackage.fileExtension : nil, in: folder)
        try fm.moveItem(at: url, to: destination)
        return destination
    }

    @discardableResult
    public func duplicate(_ url: URL) throws -> URL {
        let isNote = url.pathExtension == NotePackage.fileExtension
        let base = (isNote ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent) + " copy"
        let destination = uniqueURL(named: base, extension: isNote ? NotePackage.fileExtension : nil, in: url.deletingLastPathComponent())
        try fm.copyItem(at: url, to: destination)
        if isNote {
            let package = NotePackage(url: destination)
            var manifest = try package.readManifest()
            manifest.id = UUID()
            manifest.title = base
            manifest.modifiedAt = Date()
            try package.writeManifest(manifest)
        }
        return destination
    }

    // MARK: Pinning

    public func setPinned(_ pinned: Bool, for url: URL) throws {
        let package = NotePackage(url: url)
        var manifest = try package.readManifest()
        if pinned {
            manifest.extensions[NoteManifest.pinnedKey] = .bool(true)
        } else {
            manifest.extensions[NoteManifest.pinnedKey] = nil
        }
        try package.writeManifest(manifest)
    }

    // MARK: Trash

    /// Moves an item into the trash, remembering where it was.
    public func delete(_ url: URL, now: Date = Date()) throws {
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let isNote = url.pathExtension == NotePackage.fileExtension
        let name = isNote ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
        let destination = uniqueURL(named: name, extension: isNote ? NotePackage.fileExtension : nil, in: trash)
        let folder = relativePath(of: url.deletingLastPathComponent()) ?? ""
        try fm.moveItem(at: url, to: destination)
        var index = readTrashIndex()
        index[destination.lastPathComponent] = DeletionInfo(originalFolder: folder, deletedAt: now)
        writeTrashIndex(index)
    }

    /// Trashed items, most recently deleted first.
    public func trashedItems() -> [LibraryEntry] {
        let index = readTrashIndex()
        return contents(of: trash).sorted {
            (index[$0.url.lastPathComponent]?.deletedAt ?? $0.modifiedAt) > (index[$1.url.lastPathComponent]?.deletedAt ?? $1.modifiedAt)
        }
    }

    public func deletionInfo(for url: URL) -> DeletionInfo? {
        readTrashIndex()[url.lastPathComponent]
    }

    /// Moves a trashed item back to its original folder, or the library root if that folder is gone.
    @discardableResult
    public func restore(_ url: URL) throws -> URL {
        var index = readTrashIndex()
        var destination = root
        if let info = index[url.lastPathComponent], !info.originalFolder.isEmpty {
            let folder = root.appendingPathComponent(info.originalFolder, isDirectory: true)
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
               !folder.standardizedFileURL.path.hasPrefix(trash.standardizedFileURL.path) {
                destination = folder
            }
        }
        let restored = try move(url, to: destination)
        index[url.lastPathComponent] = nil
        writeTrashIndex(index)
        return restored
    }

    /// Permanently deletes one trashed item.
    public func deletePermanently(_ url: URL) throws {
        try fm.removeItem(at: url)
        var index = readTrashIndex()
        index[url.lastPathComponent] = nil
        writeTrashIndex(index)
    }

    public func emptyTrash() throws {
        if fm.fileExists(atPath: trash.path) { try fm.removeItem(at: trash) }
    }

    /// Permanently deletes items that have been in the trash for more than `days` days.
    public func purgeTrash(olderThan days: Int = 30, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        var index = readTrashIndex()
        for item in contents(of: trash) {
            let deleted = index[item.url.lastPathComponent]?.deletedAt ?? item.modifiedAt
            guard deleted < cutoff else { continue }
            try? fm.removeItem(at: item.url)
            index[item.url.lastPathComponent] = nil
        }
        writeTrashIndex(index)
    }

    private var trashIndexURL: URL { trash.appendingPathComponent(Self.trashIndexName) }

    private func readTrashIndex() -> [String: DeletionInfo] {
        guard let data = try? Data(contentsOf: trashIndexURL) else { return [:] }
        return (try? NoteJSON.decoder.decode([String: DeletionInfo].self, from: data)) ?? [:]
    }

    private func writeTrashIndex(_ index: [String: DeletionInfo]) {
        guard fm.fileExists(atPath: trash.path) else { return }
        try? NoteJSON.encoder.encode(index).write(to: trashIndexURL, options: .atomic)
    }

    /// A folder's path relative to the library root, compared by resolved components so
    /// `/var` and `/private/var` spellings of the same container match.
    public func relativePath(of folder: URL) -> String? {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let target = folder.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard target.count >= base.count, Array(target.prefix(base.count)) == base else { return nil }
        return target.dropFirst(base.count).joined(separator: "/")
    }

    // MARK: Names

    public func uniqueURL(named name: String, extension ext: String?, in folder: URL) -> URL {
        func candidate(_ n: String) -> URL {
            let url = folder.appendingPathComponent(n, isDirectory: true)
            return ext.map { url.appendingPathExtension($0) } ?? url
        }
        var url = candidate(name)
        var counter = 2
        while fm.fileExists(atPath: url.path) {
            url = candidate("\(name) \(counter)")
            counter += 1
        }
        return url
    }

    func sanitized(_ name: String, fallback: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = cleaned.hasPrefix(".") ? String(cleaned.drop { $0 == "." }) : cleaned
        return trimmed.isEmpty ? fallback : String(trimmed.prefix(120))
    }
}
