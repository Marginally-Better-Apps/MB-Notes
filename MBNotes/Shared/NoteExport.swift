import CoreTransferable
import NoteEngine
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let mbNote = UTType(exportedAs: "com.marginallybetter.notes.note")
    static let mbNoteArchive = UTType(exportedAs: "com.marginallybetter.notes.archive", conformingTo: .zip)
    static let mbPack = UTType(exportedAs: "com.marginallybetter.notes.pack", conformingTo: .zip)
}

/// A note shared as a PDF. Pages render lazily when the share sheet asks for the file.
struct NotePDFExport: Transferable {
    let package: NotePackage
    let catalog: PackCatalog
    var includeTranscripts = false

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .pdf) { export in
            let manifest = try export.package.readManifest()
            let renderer = PageRenderer(package: export.package, manifest: manifest, catalog: export.catalog)
            let url = try PDFExporter(renderer: renderer).export(options: .init(includeRecognizedText: true, includeTranscripts: export.includeTranscripts))
            return SentTransferredFile(url)
        }
        .suggestedFileName { export in
            ((try? export.package.readManifest().title) ?? "Note") + ".pdf"
        }
    }
}

/// A note shared as a single `.mbnotes` file that another MB Notes user can open.
struct NoteArchiveExport: Transferable {
    let package: NotePackage
    var includeRecordings = true

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .mbNoteArchive) { export in
            SentTransferredFile(try export.package.exportArchive(includeRecordings: export.includeRecordings))
        }
        .suggestedFileName { export in
            ((try? export.package.readManifest().title) ?? "Note") + "." + NotePackage.archiveExtension
        }
    }
}

/// Shares a pack as a `.mbpack` archive.
struct PackExport: Transferable {
    let registry: PackRegistry
    let packID: String
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .mbPack) { export in
            SentTransferredFile(try export.registry.exportArchive(packID: export.packID))
        }
        .suggestedFileName { "\($0.name).mbpack" }
    }
}

/// A folder tree built from the library, for the sidebar and move sheet.
struct FolderNode: Identifiable, Hashable {
    let url: URL
    let name: String
    let metadata: FolderMetadata
    let noteCount: Int
    var children: [FolderNode]?

    var id: URL { url }

    static func tree(for library: LibraryStore) -> [FolderNode] {
        func build(_ folder: URL) -> [FolderNode] {
            let entries = library.contents(of: folder, sort: .name)
            return entries.filter(\.isFolder).map { entry in
                let kids = build(entry.url)
                return FolderNode(url: entry.url, name: entry.name, metadata: entry.folder ?? FolderMetadata(color: "#6A45E0", symbol: "folder.fill"),
                                  noteCount: entry.itemCount ?? 0, children: kids.isEmpty ? nil : kids)
            }
        }
        return build(library.root)
    }

    /// Every node, depth first, with its nesting depth.
    static func flatten(_ nodes: [FolderNode], depth: Int = 0) -> [(node: FolderNode, depth: Int)] {
        nodes.flatMap { [($0, depth)] + flatten($0.children ?? [], depth: depth + 1) }
    }
}

extension EnvironmentValues {
    /// Namespace for the zoom transition from a library tile into the editor.
    @Entry var zoomNamespace: Namespace.ID?
}

/// Marks a tile as the source of the editor's zoom transition when a namespace is available.
struct MatchedSource: ViewModifier {
    let id: URL
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}
