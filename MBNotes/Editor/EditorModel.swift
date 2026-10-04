import NoteEngine
import NoteIntelligence
import Observation
import PDFKit
import PencilKit
import SwiftUI

enum EditorTool: String, CaseIterable, Identifiable {
    /// Pencil and finger draw with the PencilKit tool picker.
    case draw
    /// Tap a page to place a text box.
    case text
    /// Move, resize, and delete stickers, images, and text boxes.
    case arrange

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .draw: return "pencil.tip"
        case .text: return "character.cursor.ibeam"
        case .arrange: return "hand.point.up.left"
        }
    }

    var title: String {
        switch self {
        case .draw: return "Draw"
        case .text: return "Type"
        case .arrange: return "Arrange"
        }
    }
}

/// Everything about the open note: pages, ink, elements, and saving.
@MainActor
@Observable
final class EditorModel {
    let package: NotePackage
    private(set) var catalog: PackCatalog
    var manifest: NoteManifest
    /// Ink per page in page coordinates.
    private(set) var drawings: [UUID: PKDrawing] = [:]

    var tool: EditorTool = .draw
    var fingerDrawing: Bool {
        didSet { UserDefaults.standard.set(fingerDrawing, forKey: "fingerDrawing") }
    }
    var shapeSnapping: Bool {
        didSet { UserDefaults.standard.set(shapeSnapping, forKey: "shapeSnapping") }
    }
    var currentPageIndex = 0
    var pageCount: Int { manifest.pages.count }
    /// Bumped when pages are added, removed, reordered, or restyled.
    private(set) var layoutVersion = 0
    private(set) var isSaving = false
    var recognitionByPage: [UUID: PageRecognition] = [:]

    weak var canvas: NoteCanvasController?
    let recording: RecordingController

    private var saveTask: Task<Void, Never>?
    private var recognitionTasks: [UUID: Task<Void, Never>] = [:]
    private var savedInk: [UUID: Data] = [:]

    init(package: NotePackage, catalog: PackCatalog) throws {
        self.package = package
        self.catalog = catalog
        var manifest = try package.readManifest()
        if manifest.pages.isEmpty {
            manifest.pages = [PageSpec(size: .letter, paper: manifest.defaultPaper)]
        }
        self.manifest = manifest
        let defaults = UserDefaults.standard
        fingerDrawing = defaults.object(forKey: "fingerDrawing") as? Bool ?? !UIPencilInteraction.prefersPencilOnlyDrawing
        shapeSnapping = defaults.object(forKey: "shapeSnapping") as? Bool ?? true
        recording = RecordingController(package: package)
        for page in manifest.pages {
            if let data = package.readInk(for: page.id) {
                savedInk[page.id] = data
                drawings[page.id] = (try? PKDrawing(data: data)) ?? PKDrawing()
            }
            if let recognition = package.readRecognition(for: page.id) {
                recognitionByPage[page.id] = recognition
            }
        }
        recording.editor = self
    }

    var renderer: PageRenderer { PageRenderer(package: package, manifest: manifest, catalog: catalog) }

    func drawing(for page: UUID) -> PKDrawing {
        drawings[page] ?? PKDrawing()
    }

    // MARK: Ink

    /// Called by the canvas with each page's current ink.
    func inkChanged(_ pages: [UUID: PKDrawing]) {
        var changed: [UUID] = []
        for (id, drawing) in pages where drawings[id]?.strokes.count != drawing.strokes.count || drawings[id]?.bounds != drawing.bounds {
            changed.append(id)
        }
        drawings = pages
        for id in changed { scheduleRecognition(for: id) }
        scheduleSave()
    }

    /// Updates ink without scheduling a save, used while a save is already running.
    func replaceInk(_ pages: [UUID: PKDrawing]) {
        drawings = pages
    }

    // MARK: Pages

    func addPage(after index: Int? = nil, paper: PaperRef? = nil) {
        canvas?.flushInk()
        let reference = manifest.pages[safe: index ?? currentPageIndex] ?? manifest.pages.last
        let size = reference?.size ?? .letter
        let page = PageSpec(size: size, paper: paper ?? reference?.paper ?? manifest.defaultPaper)
        let insertAt = min((index ?? currentPageIndex) + 1, manifest.pages.count)
        manifest.pages.insert(page, at: insertAt)
        pagesChanged()
        canvas?.scroll(toPage: insertAt)
    }

    func duplicatePage(_ index: Int) {
        canvas?.flushInk()
        guard let original = manifest.pages[safe: index] else { return }
        var copy = original
        copy.id = UUID()
        copy.elements = original.elements.map { var e = $0; e.id = UUID(); return e }
        manifest.pages.insert(copy, at: index + 1)
        drawings[copy.id] = drawings[original.id]
        pagesChanged()
    }

    func deletePage(_ index: Int) {
        guard manifest.pages.count > 1, let page = manifest.pages[safe: index] else { return }
        canvas?.flushInk()
        manifest.pages.remove(at: index)
        drawings[page.id] = nil
        package.removePageFiles(page.id)
        savedInk[page.id] = nil
        currentPageIndex = min(currentPageIndex, manifest.pages.count - 1)
        pagesChanged()
    }

    func movePage(from source: IndexSet, to destination: Int) {
        canvas?.flushInk()
        manifest.pages.move(fromOffsets: source, toOffset: destination)
        pagesChanged()
    }

    func setPaper(_ paper: PaperRef, forPage index: Int? = nil, allPages: Bool = false) {
        canvas?.flushInk()
        if allPages {
            for i in manifest.pages.indices where manifest.pages[i].source == nil { manifest.pages[i].paper = paper }
            manifest.defaultPaper = paper
        } else if let i = index ?? Optional(currentPageIndex), manifest.pages.indices.contains(i) {
            manifest.pages[i].paper = paper
        }
        pagesChanged()
    }

    func appendDocument(_ url: URL) async {
        canvas?.flushInk()
        do {
            let pdf = try await DocumentImporter.convertToPDF(url)
            let added = try DocumentImporter.appendPDF(pdf, to: package, manifest: &manifest)
            pagesChanged()
            if let first = added.first, let index = manifest.pages.firstIndex(where: { $0.id == first.id }) {
                canvas?.scroll(toPage: index)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var errorMessage: String?

    private func pagesChanged() {
        layoutVersion += 1
        scheduleSave()
    }

    // MARK: Elements

    func addElement(_ element: PageElement, toPage index: Int) {
        guard manifest.pages.indices.contains(index) else { return }
        manifest.pages[index].elements.append(element)
        canvas?.reloadElements(page: index)
        scheduleSave()
    }

    func updateElement(_ element: PageElement, onPage pageID: UUID) {
        guard let p = manifest.pages.firstIndex(where: { $0.id == pageID }),
              let e = manifest.pages[p].elements.firstIndex(where: { $0.id == element.id }) else { return }
        manifest.pages[p].elements[e] = element
        scheduleSave()
    }

    func removeElement(_ id: UUID, onPage pageID: UUID) {
        guard let p = manifest.pages.firstIndex(where: { $0.id == pageID }) else { return }
        manifest.pages[p].elements.removeAll { $0.id == id }
        canvas?.reloadElements(page: p)
        scheduleSave()
    }

    func addSticker(_ ref: ContentRef) {
        let index = currentPageIndex
        guard let page = manifest.pages[safe: index] else { return }
        let side = min(page.size.width, page.size.height) * 0.22
        let center = canvas?.visibleCenter(onPage: index) ?? CGPoint(x: page.size.width / 2, y: page.size.height / 2)
        var frame = Rect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        if let sticker = catalog.sticker(ref), let canvas = sticker.canvas, canvas.width > canvas.height {
            frame.height = side * canvas.height / canvas.width
            frame.width = side
        }
        addElement(PageElement(kind: .sticker, frame: frame, rotation: Double.random(in: -0.12...0.12), sticker: ref), toPage: index)
        tool = .arrange
    }

    func addImage(_ data: Data) {
        guard let image = UIImage(data: data), let png = image.pngData() ?? image.jpegData(compressionQuality: 0.9) else { return }
        let index = currentPageIndex
        guard let page = manifest.pages[safe: index], let path = try? package.addData(png, into: "media", fileExtension: "png") else { return }
        let width = page.size.width * 0.5
        let height = width * image.size.height / max(image.size.width, 1)
        let center = canvas?.visibleCenter(onPage: index) ?? CGPoint(x: page.size.width / 2, y: page.size.height / 2)
        addElement(PageElement(kind: .image, frame: Rect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height), image: path), toPage: index)
        tool = .arrange
    }

    // MARK: Saving

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        saveTask?.cancel()
        canvas?.flushInk(notify: false)
        manifest.modifiedAt = Date()
        NoteFactory.embedResources(in: &manifest, catalog: catalog)
        do {
            try package.writeManifest(manifest)
            for page in manifest.pages {
                let data = drawings[page.id].map { $0.strokes.isEmpty ? Data() : $0.dataRepresentation() } ?? Data()
                if savedInk[page.id] != data {
                    try package.writeInk(data, for: page.id)
                    savedInk[page.id] = data
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Saves and writes the library thumbnail when the note closes.
    func close() {
        save()
        recording.stopPlayback()
        if let first = manifest.pages.first {
            let image = renderer.image(for: first, width: 360, ink: drawings[first.id])
            if let png = image.pngData() { try? package.writeThumbnail(png) }
        }
        let text = noteContext(includeTranscripts: false)
        let title = manifest.title
        let package = package
        // Tag notes with on-device topics in the background.
        Task.detached {
            let topics = await TextInsights.topics(for: title + "\n" + text)
            guard !topics.isEmpty, var manifest = try? package.readManifest() else { return }
            let merged = Array(Set(manifest.tags + topics)).sorted()
            guard merged != manifest.tags else { return }
            manifest.tags = merged
            try? package.writeManifest(manifest)
        }
    }

    func rename(_ title: String) {
        manifest.title = title
        layoutVersion += 1
        scheduleSave()
    }

    // MARK: Handwriting recognition

    private func scheduleRecognition(for pageID: UUID) {
        recognitionTasks[pageID]?.cancel()
        recognitionTasks[pageID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.recognize(pageID)
        }
    }

    func recognize(_ pageID: UUID) async {
        guard let page = manifest.pages.first(where: { $0.id == pageID }) else { return }
        let drawing = drawing(for: pageID)
        let fingerprint = HandwritingRecognizer.fingerprint(of: drawing.dataRepresentation())
        if recognitionByPage[pageID]?.inkFingerprint == fingerprint { return }
        let lines = (try? await HandwritingRecognizer.recognize(drawing, pageSize: page.size)) ?? []
        let recognition = PageRecognition(inkFingerprint: fingerprint, lines: lines)
        recognitionByPage[pageID] = recognition
        try? package.writeRecognition(recognition, for: pageID)
    }

    /// Recognizes every page that has changed, for exports and AI.
    func recognizeAll() async {
        for page in manifest.pages { await recognize(page.id) }
    }

    // MARK: Text for search, export, and AI

    func noteContext(includeTranscripts: Bool = true) -> String {
        var parts: [String] = []
        for (index, page) in manifest.pages.enumerated() {
            var pageText: [String] = []
            pageText += page.elements.compactMap { $0.text?.string }.filter { !$0.isEmpty }
            if let recognized = recognitionByPage[page.id]?.text, !recognized.isEmpty { pageText.append(recognized) }
            if let source = page.source, let url = package.fileURL(source.file), let text = SourceText.text(of: url, page: source.pageIndex), !text.isEmpty {
                pageText.append(text)
            }
            if !pageText.isEmpty { parts.append("Page \(index + 1):\n" + pageText.joined(separator: "\n")) }
        }
        if includeTranscripts {
            for recording in manifest.recordings {
                if let transcript = package.readTranscript(recording) {
                    parts.append("Recording “\(recording.title)” transcript:\n" + transcript.visibleText())
                }
            }
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: Export

    func exportPDF(includeTranscripts: Bool) async -> URL? {
        save()
        await recognizeAll()
        return try? PDFExporter(renderer: renderer).export(options: .init(includeRecognizedText: true, includeTranscripts: includeTranscripts), inkOverrides: drawings)
    }

    /// A zipped copy of the note package for sharing with other MB Notes users.
    func exportPackage() -> URL? {
        save()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(package.url.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: package.url, to: destination)
            return destination
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Text embedded in imported PDFs, so slides and handouts are searchable and usable by AI.
enum SourceText {
    private static let cache = NSCache<NSURL, PDFDocument>()

    static func text(of url: URL, page: Int) -> String? {
        let document = cache.object(forKey: url as NSURL) ?? PDFDocument(url: url)
        guard let document else { return nil }
        cache.setObject(document, forKey: url as NSURL)
        return document.page(at: page)?.string
    }
}
