import CoreGraphics
import Foundation
import ZIPFoundation
import Testing
@testable import NoteEngine

@Suite struct LengthTests {
    @Test func numbersAndPercentages() {
        #expect(Length.points(12).resolve(axis: 100, parameters: [:]) == 12)
        #expect(Length.expression("50%").resolve(axis: 200, parameters: [:]) == 100)
        #expect(Length.expression("100% - 36").resolve(axis: 612, parameters: [:]) == 576)
    }

    @Test func parametersAndPrecedence() {
        let p = ["spacing": 24.0, "margin": 10]
        #expect(Length.expression("$spacing * 2 + $margin").resolve(axis: 0, parameters: p) == 58)
        #expect(Length.expression("($spacing + $margin) / 2").resolve(axis: 0, parameters: p) == 17)
        #expect(Length.expression("-$margin").resolve(axis: 0, parameters: p) == -10)
    }

    @Test func malformedExpressionsResolveToZero() {
        #expect(Length.expression("12 +").resolve(axis: 100, parameters: [:]) == 0)
        #expect(Length.expression("abc").resolve(axis: 100, parameters: [:]) == 0)
    }
}

@Suite struct ColorTests {
    @Test func hexForms() throws {
        let c = try #require(ColorSpec.components("#FF8000"))
        #expect(c.0 == 1 && abs(c.1 - 128.0 / 255) < 0.001 && c.2 == 0 && c.3 == 1)
        #expect(ColorSpec.components("#0F0")?.1 == 1)
        #expect(ColorSpec.components("#00000080")?.3 ?? 0 > 0.5)
        #expect(ColorSpec.components("red") == nil)
    }

    @Test func tokensAndAlpha() throws {
        let palette = ColorSpec.Palette(accent: ColorSpec.hex("#8056F6")!)
        let accent = try #require(ColorSpec.color("accent@0.5", palette: palette))
        #expect(abs(accent.alpha - 0.5) < 0.001)
        #expect(ColorSpec.color("paper", palette: palette) != nil)
        #expect(ColorSpec.color("nonsense", palette: palette) == nil)
    }
}

@Suite struct SVGPathTests {
    @Test func absoluteAndRelativeCommands() {
        let path = SVGPath.path(from: "M10 10 h 20 v20 H10 Z")
        #expect(path.boundingBoxOfPath == CGRect(x: 10, y: 10, width: 20, height: 20))
    }

    @Test func implicitLinetoAfterMoveto() {
        let path = SVGPath.path(from: "M0,0 10,0 10,10")
        #expect(path.boundingBoxOfPath.size == CGSize(width: 10, height: 10))
    }

    @Test func arcsStayWithinRadius() {
        let path = SVGPath.path(from: "M0 50 A50 50 0 0 1 100 50")
        let box = path.boundingBoxOfPath
        #expect(box.minY >= -0.5 && box.maxY <= 50.5 && box.width > 99)
    }

    @Test func compactNumbersAndExponents() {
        let path = SVGPath.path(from: "M.5.5L1e1-2")
        #expect(abs(path.boundingBoxOfPath.maxX - 10) < 0.001)
        #expect(abs(path.boundingBoxOfPath.minY + 2) < 0.001)
    }
}

@Suite struct FormatTests {
    @Test func contentRefParsing() {
        let ref = ContentRef(rawValue: "com.example.pack/lined")
        #expect(ref?.packID == "com.example.pack")
        #expect(ref?.itemID == "lined")
        #expect(ContentRef(rawValue: "nopack") == nil)
        let literal: ContentRef = "dots"
        #expect(literal.packID == CorePack.id)
    }

    @Test func manifestRoundTripPreservesUnknownExtensions() throws {
        var manifest = NoteManifest(title: "Bio", kind: .notebook, accentColor: "#123456", defaultPaper: PaperRef(template: "lined"))
        manifest.pages = [PageSpec(size: .letter, paper: PaperRef(template: "lined", parameters: ["spacing": 30]))]
        manifest.extensions["com.example.tool"] = .object(["score": .number(3)])
        let data = try NoteJSON.encoder.encode(manifest)
        let decoded = try NoteJSON.decoder.decode(NoteManifest.self, from: data)
        // ISO 8601 keeps milliseconds, so compare dates to that precision.
        #expect(abs(decoded.createdAt.timeIntervalSince(manifest.createdAt)) < 0.001)
        var normalized = decoded
        normalized.createdAt = manifest.createdAt
        normalized.modifiedAt = manifest.modifiedAt
        normalized.pages[0].createdAt = manifest.pages[0].createdAt
        #expect(normalized == manifest)
    }

    @Test func manifestDecodesWithMinimalFields() throws {
        let json = #"{"format":"mbnotes.note/1","id":"7A0E6A43-2C25-4E0F-9D7A-0E9B8E4B9C11"}"#
        let manifest = try NoteJSON.decoder.decode(NoteManifest.self, from: Data(json.utf8))
        #expect(manifest.pages.isEmpty)
        #expect(manifest.kind == .note)
    }

    @Test func transcriptHidesSpeakers() {
        var transcript = Transcript(recordingID: UUID(), startedAt: Date(), locale: "en-US", engine: "test")
        transcript.speakers = [.init(id: "A", name: "Professor", color: "#000"), .init(id: "B", name: "Student", color: "#111")]
        transcript.segments = [.init(start: 0, end: 1, text: "Hello class", speaker: "A"), .init(start: 1, end: 2, text: "Question", speaker: "B")]
        transcript.hiddenSpeakers = ["B"]
        #expect(transcript.visibleText() == "Professor: Hello class")
    }
}

@Suite struct PackTests {
    func makePack(_ manifest: String, files: [String: String] = [:]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("packs-\(UUID().uuidString)", isDirectory: true)
        let pack = root.appendingPathComponent("test.mbpack", isDirectory: true)
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        try manifest.write(to: pack.appendingPathComponent("pack.json"), atomically: true, encoding: .utf8)
        for (path, contents) in files {
            let url = pack.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test func loadsInlineAndIncludedItems() throws {
        let root = try makePack("""
        { "format": "mbnotes.pack/1", "id": "com.example.test", "name": "Test",
          "papers": [ { "id": "dots", "name": "Dots", "layers": [ { "type": "dots", "spacing": 20 } ] }, "papers/lined.json" ],
          "stickers": [ { "id": "star", "emoji": "⭐️" } ] }
        """, files: ["papers/lined.json": #"{ "id": "lined", "name": "Lined", "layers": [ { "type": "hlines", "spacing": "$spacing" } ], "parameters": { "spacing": { "label": "Spacing", "default": 24 } } }"#])
        let registry = PackRegistry(builtInDirectory: nil, userDirectory: root)
        let catalog = registry.reload()
        #expect(registry.loadErrors.isEmpty)
        #expect(catalog.paper(ContentRef(packID: "com.example.test", itemID: "lined"))?.parameters["spacing"]?.defaultValue == 24)
        #expect(catalog.allPapers.count == 2)
        #expect(catalog.sticker(ContentRef(packID: "com.example.test", itemID: "star"))?.emoji == "⭐️")
    }

    @Test func reportsMissingIncludes() throws {
        let root = try makePack(#"{ "id": "com.example.broken", "name": "Broken", "papers": ["nope.json"] }"#)
        let registry = PackRegistry(builtInDirectory: nil, userDirectory: root)
        registry.reload()
        #expect(registry.loadErrors["test.mbpack"] == .missingInclude("test.mbpack", "nope.json"))
    }

    @Test func refusesPathsOutsideThePack() throws {
        let root = try makePack(#"{ "id": "com.example.escape", "name": "Escape", "papers": ["../../etc/passwd"] }"#)
        let registry = PackRegistry(builtInDirectory: nil, userDirectory: root)
        registry.reload()
        #expect(registry.catalog.packs.isEmpty)
    }

    @Test func userPacksCannotReplaceCore() throws {
        let root = try makePack(#"{ "id": "com.marginallybetter.core", "name": "Fake core" }"#)
        let registry = PackRegistry(builtInDirectory: nil, userDirectory: root)
        registry.reload()
        #expect(registry.catalog.packs.isEmpty)
        #expect(registry.loadErrors["test.mbpack"] == .reservedIdentifier("com.marginallybetter.core"))
    }

    @Test func embeddedSnapshotsFollowUsage() {
        let paper = PaperTemplate(id: "lined", name: "Lined")
        let pack = LoadedPack(manifest: try! NoteJSON.decoder.decode(PackManifest.self, from: Data(#"{"id":"p","name":"P"}"#.utf8)),
                              rootURL: URL(fileURLWithPath: "/tmp"), isBuiltIn: false, papers: [paper], covers: [], stickers: [], palettes: [], symbolSets: [])
        let catalog = PackCatalog(packs: [pack])
        var manifest = NoteManifest(title: "T", kind: .note, accentColor: "#000000", defaultPaper: PaperRef(template: ContentRef(packID: "p", itemID: "lined")))
        manifest.pages = [PageSpec(size: .letter, paper: PaperRef(template: ContentRef(packID: "p", itemID: "lined")))]
        NoteFactory.embedResources(in: &manifest, catalog: catalog)
        #expect(manifest.embedded.papers["p/lined"] == paper)
        // Without the pack installed, the snapshot still renders the right template.
        #expect(PackCatalog.empty.resolvePaper(ContentRef(packID: "p", itemID: "lined"), embedded: manifest.embedded).name == "Lined")
    }
}

@Suite struct LibraryTests {
    @Test func createRenameMoveAndTrash() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString)", isDirectory: true)
        let library = LibraryStore(root: root)
        let folder = try library.createFolder(named: "Biology", in: root, metadata: FolderMetadata(color: "#00FF00", symbol: "leaf.fill"))
        let note = try library.createNote(NoteManifest(title: "Cells", kind: .note, accentColor: "#000000", defaultPaper: PaperRef(template: "blank")), in: folder)
        #expect(library.contents(of: folder).first?.name == "Cells")
        #expect(library.contents(of: root).first?.folder?.symbol == "leaf.fill")

        let renamed = try library.rename(note.url, to: "Cell Biology")
        #expect(renamed.lastPathComponent == "Cell Biology.mbnote")
        #expect(try NotePackage(url: renamed).readManifest().title == "Cell Biology")

        let moved = try library.move(renamed, to: root)
        #expect(library.allNotes().map { $0.url.resolvingSymlinksInPath() } == [moved.resolvingSymlinksInPath()])

        try library.delete(moved)
        #expect(library.allNotes().isEmpty)
        #expect(library.trashedItems().count == 1)
    }

    @Test func newFilesResolveInsideNotesFoundByListing() throws {
        // The temporary directory sits under /var, a symlink to /private/var, like an iOS
        // app container. Listing returns /private/var URLs; new files must still resolve.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString)", isDirectory: true)
        let library = LibraryStore(root: root)
        _ = try library.createNote(NoteManifest(title: "Bio", kind: .note, accentColor: "#000000", defaultPaper: PaperRef(template: "blank")), in: root)
        let listed = try #require(library.contents(of: root).first)
        let package = NotePackage(url: listed.url)
        let audio = try #require(package.fileURL("recordings/\(UUID().uuidString).m4a"))
        #expect(audio.deletingLastPathComponent().deletingLastPathComponent() == listed.url)
        #expect(package.fileURL("../escape.txt") == nil)
        #expect(package.fileURL("media/../../escape.txt") == nil)
        #expect(package.fileURL("/etc/passwd") == nil)
        #expect(package.fileURL("") == nil)
    }

    @Test func restoreReturnsItemsToWhereTheyWere() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString)", isDirectory: true)
        let library = LibraryStore(root: root)
        let folder = try library.createFolder(named: "Chem", in: root, metadata: FolderMetadata(color: "#000", symbol: "folder"))
        let note = try library.createNote(NoteManifest(title: "Acids", kind: .note, accentColor: "#000000", defaultPaper: PaperRef(template: "blank")), in: folder)
        try library.delete(note.url)
        let trashed = try #require(library.trashedItems().first)
        #expect(library.deletionInfo(for: trashed.url)?.originalFolder == "Chem")
        let restored = try library.restore(trashed.url)
        #expect(restored.deletingLastPathComponent().lastPathComponent == "Chem")
        #expect(library.trashedItems().isEmpty)

        // Restoring into a folder that no longer exists falls back to the library root.
        let other = try library.createNote(NoteManifest(title: "Bases", kind: .note, accentColor: "#000000", defaultPaper: PaperRef(template: "blank")), in: folder)
        try library.delete(other.url)
        try library.delete(folder)
        let orphan = try #require(library.trashedItems().first { $0.name == "Bases" })
        let back = try library.restore(orphan.url)
        #expect(back.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() == root.standardizedFileURL.resolvingSymlinksInPath())
    }

    @Test func purgesItemsDeletedLongAgo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString)", isDirectory: true)
        let library = LibraryStore(root: root)
        let note = try library.createNote(NoteManifest(title: "Old", kind: .note, accentColor: "#000000", defaultPaper: PaperRef(template: "blank")), in: root)
        try library.delete(note.url)
        library.purgeTrash(olderThan: 30, now: Date().addingTimeInterval(31 * 86_400))
        #expect(library.trashedItems().isEmpty)
    }

    @Test func archivesRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString)", isDirectory: true)
        let library = LibraryStore(root: root)
        let note = try library.createNote(NoteManifest(title: "Shared", kind: .note, accentColor: "#000000", defaultPaper: PaperRef(template: "blank")), in: root)
        try Data([1, 2, 3]).write(to: note.url.appendingPathComponent("recordings/a.m4a"))
        let archive = try note.exportArchive()
        #expect(archive.pathExtension == NotePackage.archiveExtension)
        let imported = try NotePackage.importArchive(archive, into: root)
        #expect(imported.url.lastPathComponent == "Shared 2.mbnote")
        #expect(try imported.readManifest().title == "Shared")
        #expect(FileManager.default.fileExists(atPath: imported.url.appendingPathComponent("recordings/a.m4a").path))
        let light = try note.exportArchive(includeRecordings: false)
        let lightImport = try NotePackage.importArchive(light, into: root)
        #expect(!FileManager.default.fileExists(atPath: lightImport.url.appendingPathComponent("recordings/a.m4a").path))
    }

    @Test func pinningIsStoredInTheNote() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString)", isDirectory: true)
        let library = LibraryStore(root: root)
        let note = try library.createNote(NoteManifest(title: "Pinned", kind: .note, accentColor: "#000000", defaultPaper: PaperRef(template: "blank")), in: root)
        try library.setPinned(true, for: note.url)
        #expect(library.contents(of: root).first?.isPinned == true)
        try library.setPinned(false, for: note.url)
        #expect(library.contents(of: root).first?.isPinned == false)
    }

    @Test func uniqueNamesAndSanitizing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString)", isDirectory: true)
        let library = LibraryStore(root: root)
        let a = try library.createFolder(named: "Notes", in: root, metadata: FolderMetadata(color: "#000", symbol: "folder"))
        let b = try library.createFolder(named: "Notes", in: root, metadata: FolderMetadata(color: "#000", symbol: "folder"))
        #expect(a.lastPathComponent == "Notes")
        #expect(b.lastPathComponent == "Notes 2")
        let hidden = try library.createFolder(named: "../.secret/x", in: root, metadata: FolderMetadata(color: "#000", symbol: "folder"))
        #expect(hidden.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
    }
}

@Suite struct OpenDocumentTests {
    @Test func convertsHeadingsListsAndTables() throws {
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content xmlns:office="o" xmlns:text="t" xmlns:table="tb" xmlns:style="s" xmlns:fo="f">
        <office:automatic-styles><style:style style:name="B"><style:text-properties fo:font-weight="bold"/></style:style></office:automatic-styles>
        <office:body><office:text>
        <text:h text:outline-level="2">Week 1</text:h>
        <text:p>Mitochondria <text:span text:style-name="B">powerhouse</text:span> &amp; more</text:p>
        <text:list><text:list-item><text:p>One</text:p></text:list-item></text:list>
        <table:table table:name="Data"><table:table-row><table:table-cell><text:p>A1</text:p></table:table-cell></table:table-row></table:table>
        </office:text></office:body></office:document-content>
        """
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("odt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try content.write(to: dir.appendingPathComponent("content.xml"), atomically: true, encoding: .utf8)
        let odt = dir.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).odt")
        try FileManager.default.zipItem(at: dir.appendingPathComponent("content.xml"), to: odt)
        let html = try OpenDocumentConverter.convert(odt).html
        #expect(html.contains("<h2>Week 1</h2>"))
        #expect(html.contains("<span style=\"font-weight:bold\">powerhouse</span> &amp; more"))
        #expect(html.contains("<ul><li><p>One</p></li></ul>"))
        #expect(html.contains("<h3>Data</h3><table><tr><td><p>A1</p></td></tr></table>"))
    }
}
