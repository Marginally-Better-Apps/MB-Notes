import NoteEngine
import Observation
import SwiftUI
import UIKit

/// App-wide state: the library on disk, installed packs, and which note is open.
@MainActor
@Observable
final class AppModel {
    let library: LibraryStore
    let packs: PackRegistry
    private(set) var catalog: PackCatalog = .empty
    /// Bumped whenever the library changes on disk so grids reload.
    private(set) var libraryVersion = 0
    var openNote: OpenNote?
    var alert: AppAlert?
    var isImporting = false

    struct OpenNote: Identifiable {
        let package: NotePackage
        var id: URL { package.url }
    }

    struct AppAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        library = LibraryStore(root: documents.appendingPathComponent("Library", isDirectory: true))
        packs = PackRegistry(
            builtInDirectory: Bundle.main.url(forResource: "Packs", withExtension: nil),
            userDirectory: documents.appendingPathComponent("Packs", isDirectory: true)
        )
        reloadPacks()
        seedLibraryIfNeeded()
        #if DEBUG
        // Screenshot and test hook: `-openFirstNote` opens the newest note on launch.
        if ProcessInfo.processInfo.arguments.contains("-openFirstNote"), let first = library.allNotes().first {
            openNote = OpenNote(package: NotePackage(url: first.url))
        }
        #endif
    }

    func reloadPacks() {
        catalog = packs.reload()
    }

    func refreshLibrary() {
        libraryVersion += 1
    }

    func show(_ error: Error, title: String = "Something went wrong") {
        alert = AppAlert(title: title, message: error.localizedDescription)
    }

    // MARK: Preferences

    var preferredPageSize: PageSize {
        switch UserDefaults.standard.string(forKey: "pageSize") ?? "letter" {
        case "a4": return .a4
        case "a5": return .a5
        default: return .letter
        }
    }

    // MARK: Creating things

    func nextAccent() -> String {
        let count = library.allNotes().count + library.allFolders().count
        return Brand.accentHexes[count % Brand.accentHexes.count]
    }

    @discardableResult
    func createFolder(named name: String, in parent: URL, color: String, symbol: String) -> URL? {
        do {
            let url = try library.createFolder(named: name, in: parent, metadata: FolderMetadata(color: color, symbol: symbol))
            refreshLibrary()
            return url
        } catch {
            show(error)
            return nil
        }
    }

    func createNotebook(title: String, cover: ContentRef, accent: String, paper: PaperRef, titlePage: ContentRef?, size: PageSize, in folder: URL, open: Bool = true) {
        let manifest = NoteFactory.notebook(title: title, cover: cover, accentColor: accent, paper: paper, titlePage: titlePage, size: size, catalog: catalog)
        create(manifest, in: folder, open: open)
    }

    func createNote(title: String, accent: String, paper: PaperRef, size: PageSize, in folder: URL, open: Bool = true) {
        let manifest = NoteFactory.note(title: title, accentColor: accent, paper: paper, size: size, catalog: catalog)
        create(manifest, in: folder, open: open)
    }

    private func create(_ manifest: NoteManifest, in folder: URL, open: Bool) {
        do {
            let package = try library.createNote(manifest, in: folder)
            refreshLibrary()
            if open { openNote = OpenNote(package: package) }
        } catch {
            show(error)
        }
    }

    // MARK: Importing

    /// Imports documents as new notes, or installs packs and note packages.
    func importFiles(_ urls: [URL], into folder: URL) async {
        isImporting = true
        defer {
            isImporting = false
            refreshLibrary()
        }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try await importFile(url, into: folder)
            } catch {
                show(error, title: "Couldn't import \(url.lastPathComponent)")
            }
        }
    }

    private func importFile(_ url: URL, into folder: URL) async throws {
        switch url.pathExtension.lowercased() {
        case PackRegistry.packExtension:
            let pack = try packs.install(from: url)
            reloadPacks()
            alert = AppAlert(title: "Installed \(pack.manifest.name)", message: "Its papers, covers, and stickers are ready to use.")
        case NotePackage.fileExtension:
            let name = url.deletingPathExtension().lastPathComponent
            let destination = library.uniqueURL(named: name, extension: NotePackage.fileExtension, in: folder)
            try FileManager.default.copyItem(at: url, to: destination)
            let package = NotePackage(url: destination)
            var manifest = try package.readManifest()
            manifest.id = UUID()
            try package.writeManifest(manifest)
        default:
            let pdf = try await DocumentImporter.convertToPDF(url)
            let title = url.deletingPathExtension().lastPathComponent
            _ = try DocumentImporter.createNote(fromPDF: pdf, title: title, accentColor: nextAccent(), in: folder, library: library, catalog: catalog)
        }
    }

    /// Handles files opened from other apps.
    func handleOpenURL(_ url: URL) {
        Task { await importFiles([url], into: library.root) }
    }

    // MARK: First launch

    private func seedLibraryIfNeeded() {
        let key = "didSeedLibrary"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        guard library.contents(of: library.root).isEmpty else { return }
        let lined = PaperRef(template: ContentRef(packID: CorePack.id, itemID: "lined"))
        if let folder = try? library.createFolder(named: "School", in: library.root, metadata: FolderMetadata(color: "#8056F6", symbol: "graduationcap.fill", stickers: [
            PlacedSticker(sticker: ContentRef(packID: CorePack.id, itemID: "emoji-star"), x: 0.82, y: 0.3, scale: 0.9, rotation: 0.2),
        ])) {
            let manifest = NoteFactory.notebook(
                title: "Welcome to MB Notes",
                cover: ContentRef(packID: CorePack.id, itemID: "sunset"),
                accentColor: "#F76CA0",
                paper: lined,
                titlePage: ContentRef(packID: CorePack.id, itemID: "title-doodle"),
                size: preferredPageSize,
                catalog: catalog
            )
            if let package = try? library.createNote(manifest, in: folder) {
                var seeded = manifest
                if seeded.pages.count > 1 {
                    seeded.pages[1].elements = [
                        .text("Write with Apple Pencil, or turn on finger drawing in the toolbar.\n\nTap the T tool to type, the smiley to add stickers, and the record button to capture a lecture with a live transcript.\n\nEverything here is yours: notes are plain files in the Files app, and papers, covers, and stickers come from packs you can make and share.",
                              frame: Rect(x: 90, y: 110, width: 460, height: 260),
                              style: TextContent(fontSize: 18, color: "#4C3AD6")),
                    ]
                }
                try? package.writeManifest(seeded)
            }
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

    func invalidate(_ url: URL) {
        cache.removeAllObjects()
        _ = url
    }

    private func key(_ item: LibraryEntry) -> NSString {
        "\(item.url.path)|\(item.modifiedAt.timeIntervalSince1970)" as NSString
    }
}
