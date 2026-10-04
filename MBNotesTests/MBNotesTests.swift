import NoteEngine
import PDFKit
import PencilKit
import Testing
import UIKit
@testable import MBNotes

@MainActor
@Suite struct MBNotesTests {
    @Test func builtInPackShipsInTheBundle() throws {
        let packs = try #require(Bundle(for: AppModelProbe.self).url(forResource: "Packs", withExtension: nil) ?? Bundle.main.url(forResource: "Packs", withExtension: nil))
        let pack = try PackRegistry.load(from: packs.appendingPathComponent("core.mbpack"), builtIn: true)
        #expect(pack.id == CorePack.id)
        #expect(pack.papers.contains { $0.id == "lined" })
    }

    @Test func everyAlternateIconHasAPreview() {
        for theme in AppIconTheme.allCases {
            #expect(UIImage(named: theme.previewImage) != nil, "missing preview for \(theme.rawValue)")
        }
    }

    @Test func notebookStartsWithTitlePageThenPaper() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("packs-\(UUID().uuidString)")
        let registry = PackRegistry(builtInDirectory: Bundle.main.url(forResource: "Packs", withExtension: nil), userDirectory: root)
        let catalog = registry.reload()
        let manifest = NoteFactory.notebook(
            title: "Chem", cover: ContentRef(packID: CorePack.id, itemID: "classic"), accentColor: "#123456",
            paper: PaperRef(template: ContentRef(packID: CorePack.id, itemID: "dots")),
            titlePage: ContentRef(packID: CorePack.id, itemID: "title-classic"), size: .letter, catalog: catalog
        )
        #expect(manifest.pages.count == 2)
        #expect(manifest.pages[0].paper.template.itemID == "title-classic")
        #expect(manifest.embedded.covers["\(CorePack.id)/classic"] != nil)
    }
}

private final class AppModelProbe {}

@MainActor
@Suite struct ExportTests {
    @Test func exportedPDFIsSearchableAndKeepsInk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString)")
        let library = LibraryStore(root: root)
        let registry = PackRegistry(builtInDirectory: Bundle.main.url(forResource: "Packs", withExtension: nil), userDirectory: root.appendingPathComponent("packs"))
        let catalog = registry.reload()
        var manifest = NoteFactory.note(title: "Cells", accentColor: "#F76CA0", paper: PaperRef(template: ContentRef(packID: CorePack.id, itemID: "lined")), size: .letter, catalog: catalog)
        manifest.pages[0].elements = [.text("Typed mitochondria", frame: Rect(x: 72, y: 72, width: 300, height: 40))]
        let package = try library.createNote(manifest, in: root)

        // A stroke on the page, plus recognition results as Vision would write them.
        let points = (0..<20).map { i in PKStrokePoint(location: CGPoint(x: 100 + Double(i) * 10, y: 200), timeOffset: Double(i) * 0.01, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2) }
        let drawing = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))])
        let page = manifest.pages[0]
        try package.writeInk(drawing.dataRepresentation(), for: page.id)
        try package.writeRecognition(PageRecognition(inkFingerprint: "x", lines: [.init(text: "handwritten ribosome", confidence: 0.9, box: Rect(x: 100, y: 190, width: 200, height: 20))]), for: page.id)

        let url = try PDFExporter(renderer: PageRenderer(package: package, manifest: manifest, catalog: catalog)).export()
        let pdf = try #require(PDFDocument(url: url))
        #expect(pdf.pageCount == 1)
        let text = pdf.string ?? ""
        #expect(text.contains("handwritten ribosome"), "invisible OCR layer missing: \(text)")
        #expect(text.contains("Typed mitochondria"), "typed text should stay real text")
    }
}
