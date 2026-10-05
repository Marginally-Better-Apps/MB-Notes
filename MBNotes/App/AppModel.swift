import NoteEngine
import Observation
import SwiftUI
import UIKit

/// State shared by every window: the library on disk and installed packs.
/// Per-window state (the open note, alerts) lives in `SceneModel`.
@MainActor
@Observable
final class AppModel {
    let library: LibraryStore
    let packs: PackRegistry
    private(set) var catalog: PackCatalog = .empty
    /// Bumped whenever the library changes on disk so grids reload.
    private(set) var libraryVersion = 0

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        library = LibraryStore(root: documents.appendingPathComponent("Library", isDirectory: true))
        packs = PackRegistry(
            builtInDirectory: Bundle.main.url(forResource: "Packs", withExtension: nil),
            userDirectory: documents.appendingPathComponent("Packs", isDirectory: true)
        )
        reloadPacks()
        seedLibraryIfNeeded()
        library.purgeTrash()
    }

    func reloadPacks() {
        catalog = packs.reload()
    }

    func refreshLibrary() {
        libraryVersion += 1
    }

    // MARK: Preferences

    var preferredPageSize: PageSize {
        switch UserDefaults.standard.string(forKey: "pageSize") ?? "letter" {
        case "a4": return .a4
        case "a5": return .a5
        default: return .letter
        }
    }

    /// The paper used for one-tap notes; the last paper chosen in the editor or a new notebook.
    var preferredPaper: PaperRef {
        get {
            if let raw = UserDefaults.standard.string(forKey: "preferredPaper"), let ref = ContentRef(rawValue: raw), catalog.paper(ref) != nil {
                return PaperRef(template: ref)
            }
            return PaperRef(template: ContentRef(packID: CorePack.id, itemID: "lined"))
        }
        set { UserDefaults.standard.set(newValue.template.rawValue, forKey: "preferredPaper") }
    }

    // MARK: Creating things

    /// Cycles through the curated item colors so new folders and notebooks vary.
    func nextAccent() -> String {
        let defaults = UserDefaults.standard
        let index = defaults.integer(forKey: "accentCounter")
        defaults.set(index + 1, forKey: "accentCounter")
        return AppTheme.itemColors[index % AppTheme.itemColors.count]
    }

    func createFolder(named name: String, in parent: URL, color: String? = nil, symbol: String = "folder.fill") throws -> URL {
        let url = try library.createFolder(named: name, in: parent, metadata: FolderMetadata(color: color ?? nextAccent(), symbol: symbol))
        refreshLibrary()
        return url
    }

    func createNotebook(title: String, cover: ContentRef, accent: String, paper: PaperRef, titlePage: ContentRef?, size: PageSize, in folder: URL) throws -> NotePackage {
        let manifest = NoteFactory.notebook(title: title, cover: cover, accentColor: accent, paper: paper, titlePage: titlePage, size: size, catalog: catalog)
        preferredPaper = paper
        return try create(manifest, in: folder)
    }

    /// A plain note with the last-used paper, named by today's date until it gets a real title.
    func createQuickNote(in folder: URL) throws -> NotePackage {
        let title = "Note " + Date().formatted(.dateTime.month(.abbreviated).day())
        let paper = preferredPaper
        let size = NoteFactory.pageSize(for: paper.template, preferred: preferredPageSize, catalog: catalog)
        let manifest = NoteFactory.note(title: title, accentColor: AppTheme.current.accentHex, paper: paper, size: size, catalog: catalog)
        return try create(manifest, in: folder)
    }

    private func create(_ manifest: NoteManifest, in folder: URL) throws -> NotePackage {
        let package = try library.createNote(manifest, in: folder)
        refreshLibrary()
        return package
    }

    // MARK: Library edits

    func togglePinned(_ item: LibraryEntry) {
        try? library.setPinned(!item.isPinned, for: item.url)
        refreshLibrary()
    }

    func delete(_ urls: [URL]) throws {
        defer { refreshLibrary() }
        for url in urls { try library.delete(url) }
    }

    func move(_ urls: [URL], to folder: URL) throws {
        defer { refreshLibrary() }
        for url in urls { _ = try library.move(url, to: folder) }
    }

    // MARK: Importing

    enum ImportOutcome {
        case note(NotePackage)
        case pack(LoadedPack)
    }

    /// Imports a document as a new note, installs a pack, or copies in a note package.
    func importFile(_ url: URL, into folder: URL) async throws -> ImportOutcome {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        defer { refreshLibrary() }
        if url.pathExtension.lowercased() == NotePackage.archiveExtension {
            return .note(try NotePackage.importArchive(url, into: folder))
        }
        if url.pathExtension.lowercased() == NotePackage.fileExtension {
            let name = url.deletingPathExtension().lastPathComponent
            let destination = library.uniqueURL(named: name, extension: NotePackage.fileExtension, in: folder)
            try FileManager.default.copyItem(at: url, to: destination)
            let package = NotePackage(url: destination)
            var manifest = try package.readManifest()
            manifest.id = UUID()
            try package.writeManifest(manifest)
            return .note(package)
        }
        if PackInstaller.looksLikePack(url) {
            let pack = try packs.install(from: url)
            reloadPacks()
            return .pack(pack)
        }
        let pdf = try await DocumentImporter.convertToPDF(url)
        let title = url.deletingPathExtension().lastPathComponent
        let package = try DocumentImporter.createNote(fromPDF: pdf, title: title, accentColor: nextAccent(), in: folder, library: library, catalog: catalog)
        return .note(package)
    }

    /// Whether a URL points inside the library, so it can be opened in place.
    func isInLibrary(_ url: URL) -> Bool {
        library.relativePath(of: url.deletingLastPathComponent()) != nil
    }

    // MARK: First launch

    private func seedLibraryIfNeeded() {
        let key = "didSeedLibrary"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        guard library.contents(of: library.root).isEmpty else { return }
        let lined = PaperRef(template: ContentRef(packID: CorePack.id, itemID: "lined"))
        guard let folder = try? library.createFolder(named: "School", in: library.root, metadata: FolderMetadata(color: "#6A45E0", symbol: "graduationcap.fill")) else { return }
        let manifest = NoteFactory.notebook(
            title: "Welcome to MB Notes",
            cover: ContentRef(packID: CorePack.id, itemID: "cloth"),
            accentColor: "#6A45E0",
            paper: lined,
            titlePage: ContentRef(packID: CorePack.id, itemID: "title-minimal"),
            size: preferredPageSize,
            catalog: catalog
        )
        if let package = try? library.createNote(manifest, in: folder) {
            var seeded = manifest
            if seeded.pages.count > 1 {
                seeded.pages[1].elements = [
                    .text("Write with Apple Pencil, or turn on finger drawing in the toolbar.\n\nTap the T tool to type, + to add stickers and photos, and the record button to capture a lecture with a live transcript.\n\nEverything here is yours: notes are plain files in the Files app, and papers, covers, and stickers come from packs you can make and share.",
                          frame: Rect(x: 90, y: 110, width: 460, height: 260),
                          style: TextContent(fontSize: 18, color: "#1C1C1E")),
                ]
            }
            try? package.writeManifest(seeded)
        }
        refreshLibrary()
    }
}

/// Renders and caches library thumbnails.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()

    func cached(for item: LibraryEntry) -> UIImage? {
        cache.object(forKey: key(item))
    }

    func image(for item: LibraryEntry, catalog: PackCatalog, width: CGFloat = 360) async -> UIImage? {
        if let cached = cached(for: item) { return cached }
        guard let manifest = item.manifest else { return nil }
        let package = NotePackage(url: item.url)
        let image: UIImage? = await Task.detached(priority: .utility) {
            // Notes save a fresh thumbnail when they close; fall back to rendering.
            if manifest.kind != .notebook,
               let data = try? Data(contentsOf: package.thumbnailURL),
               let attributes = try? FileManager.default.attributesOfItem(atPath: package.thumbnailURL.path),
               let date = attributes[.modificationDate] as? Date, date >= manifest.modifiedAt.addingTimeInterval(-2),
               let image = UIImage(data: data) {
                return image
            }
            return PageRenderer(package: package, manifest: manifest, catalog: catalog).thumbnail(width: width)
        }.value
        if let image { cache.setObject(image, forKey: key(item)) }
        return image
    }

    private func key(_ item: LibraryEntry) -> NSString {
        "\(item.url.path)|\(item.modifiedAt.timeIntervalSince1970)" as NSString
    }
}
