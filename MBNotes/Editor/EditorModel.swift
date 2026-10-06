import NoteEngine
import NoteIntelligence
import Observation
import PDFKit
import PencilKit
import SwiftUI

/// What touches do on the canvas.
enum EditorMode: String, CaseIterable, Identifiable {
    /// One finger scrolls and pages; nothing is edited. The iPhone default.
    case view
    /// Pencil and finger draw with the PencilKit tool picker.
    case pen
    /// Tap a page to place a text box; tap a text box to edit it.
    case text
    /// Tap, move, resize, and delete stickers, images, and text boxes.
    case select

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .view: return "hand.point.up.left"
        case .pen: return "pencil.tip"
        case .text: return "textformat"
        case .select: return "cursorarrow.rays"
        }
    }

    var title: String {
        switch self {
        case .view: return "View"
        case .pen: return "Pen"
        case .text: return "Text"
        case .select: return "Select"
        }
    }
}

struct ElementSelection: Equatable {
    let pageID: UUID
    let elementID: UUID
}

/// Everything about the open note: pages, ink, elements, undo, and saving.
@MainActor
@Observable
final class EditorModel {
    let package: NotePackage
    private(set) var catalog: PackCatalog
    var manifest: NoteManifest
    /// Ink per page in page coordinates.
    private(set) var drawings: [UUID: PKDrawing] = [:]

    var mode: EditorMode = .pen {
        didSet { if mode != .select { selection = nil } }
    }
    /// While on, handwriting turns into typed text a moment after the pen lifts.
    var convertMode = false
    var fingerDrawing: Bool {
        didSet { UserDefaults.standard.set(fingerDrawing, forKey: "fingerDrawing") }
    }
    var shapeSnapping: Bool {
        didSet { UserDefaults.standard.set(shapeSnapping, forKey: "shapeSnapping") }
    }
    /// Side by side or continuous; the note can override the app setting.
    var pageAxis: PageLayout.Axis {
        didSet {
            manifest.extensions["mbnotes.pageAxis"] = .string(pageAxis.rawValue)
            layoutVersion += 1
            scheduleSave()
        }
    }
    var currentPageIndex = 0
    var pageCount: Int { manifest.pages.count }
    /// Bumped when pages are added, removed, reordered, or restyled.
    private(set) var layoutVersion = 0
    /// A page the canvas should show once it has rebuilt.
    var pendingScroll: Int?
    var selection: ElementSelection?
    private(set) var isSaving = false
    var recognitionByPage: [UUID: PageRecognition] = [:]
    var errorMessage: String?
    /// A short message to flash over the canvas, such as "Undo · Stroke".
    var hud: String?
    /// The style new text boxes get; follows the last style the user set.
    var textStyle: TextContent

    /// One undo stack per note, shared by PencilKit, text views, and model changes.
    let undoManager = UndoManager()
    private(set) var canUndo = false
    private(set) var canRedo = false
    private(set) var undoTitle = ""
    private(set) var redoTitle = ""

    weak var canvas: NoteCanvasController?
    let recording: RecordingController

    private var saveTask: Task<Void, Never>?
    private var hudTask: Task<Void, Never>?
    private var recognitionTasks: [UUID: Task<Void, Never>] = [:]
    private var savedInk: [UUID: Data] = [:]
    /// Pages removed from the manifest; their files go when the note is saved and they
    /// are still gone, so undo can bring them back in the meantime.
    private var orphanedPages = Set<UUID>()
    private var undoObservers: [NSObjectProtocol] = []

    init(package: NotePackage, catalog: PackCatalog) throws {
        self.package = package
        self.catalog = catalog
        var manifest = try package.readManifest()
        if manifest.pages.isEmpty {
            manifest.pages = [PageSpec(size: .letter, paper: manifest.defaultPaper)]
        }
        // A recording that was running when the app died becomes a normal recording.
        var recovered = false
        for index in manifest.recordings.indices where manifest.recordings[index].inProgress {
            if let fixed = RecordingController.recover(manifest.recordings[index], in: package) {
                manifest.recordings[index] = fixed
            } else {
                manifest.recordings[index].inProgress = false
            }
            recovered = true
        }
        self.manifest = manifest
        let defaults = UserDefaults.standard
        fingerDrawing = defaults.object(forKey: "fingerDrawing") as? Bool ?? !UIPencilInteraction.prefersPencilOnlyDrawing
        shapeSnapping = defaults.object(forKey: "shapeSnapping") as? Bool ?? true
        if case .string(let raw) = manifest.extensions["mbnotes.pageAxis"], let axis = PageLayout.Axis(rawValue: raw) {
            pageAxis = axis
        } else {
            pageAxis = PageLayout.Axis(rawValue: defaults.string(forKey: "pageScrollAxis") ?? "") ?? .horizontal
        }
        if let data = defaults.data(forKey: "textStyle"), let style = try? NoteJSON.decoder.decode(TextContent.self, from: data) {
            textStyle = TextContent(string: "", fontName: style.fontName, fontSize: style.fontSize, color: style.color, alignment: style.alignment)
        } else {
            textStyle = TextContent(fontSize: 17, color: "#1C1C1E")
        }
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
        undoManager.levelsOfUndo = 100
        observeUndo()
        if recovered { save() }
    }

    var renderer: PageRenderer { PageRenderer(package: package, manifest: manifest, catalog: catalog) }

    func drawing(for page: UUID) -> PKDrawing {
        drawings[page] ?? PKDrawing()
    }

    /// Changes whenever a page's ink or elements change, so thumbnails refresh.
    func pageRevision(_ pageID: UUID) -> Int {
        var hasher = Hasher()
        hasher.combine(drawings[pageID]?.strokes.count ?? 0)
        hasher.combine(drawings[pageID]?.bounds.width ?? 0)
        hasher.combine(manifest.pages.first { $0.id == pageID }?.elements)
        hasher.combine(manifest.pages.first { $0.id == pageID }?.paper)
        return hasher.finalize()
    }

    // MARK: Undo

    private func observeUndo() {
        let center = NotificationCenter.default
        for name in [NSNotification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange, .NSUndoManagerCheckpoint] {
            undoObservers.append(center.addObserver(forName: name, object: undoManager, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshUndoState() }
            })
        }
    }

    private func refreshUndoState() {
        canUndo = undoManager.canUndo
        canRedo = undoManager.canRedo
        undoTitle = undoManager.undoActionName
        redoTitle = undoManager.redoActionName
    }

    func undo() {
        guard undoManager.canUndo else { return }
        let name = undoManager.undoActionName
        canvas?.endTextEditing()
        undoManager.undo()
        flash(name.isEmpty ? "Undo" : "Undo · \(name)")
    }

    func redo() {
        guard undoManager.canRedo else { return }
        let name = undoManager.redoActionName
        canvas?.endTextEditing()
        undoManager.redo()
        flash(name.isEmpty ? "Redo" : "Redo · \(name)")
    }

    func flash(_ message: String) {
        hud = message
        hudTask?.cancel()
        hudTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            if !Task.isCancelled { self?.hud = nil }
        }
    }

    /// Snapshots pages and ink, runs `change`, and registers an undo that restores the snapshot.
    private func performPageChange(_ name: String, _ change: () -> Void) {
        canvas?.flushInk()
        let before = (pages: manifest.pages, drawings: drawings, index: currentPageIndex)
        change()
        let after = (pages: manifest.pages, drawings: drawings, index: currentPageIndex)
        registerPageUndo(name, from: after, to: before)
        pagesChanged()
    }

    private typealias PageSnapshot = (pages: [PageSpec], drawings: [UUID: PKDrawing], index: Int)

    private func registerPageUndo(_ name: String, from: PageSnapshot, to: PageSnapshot) {
        undoManager.registerUndo(withTarget: self) { model in
            model.canvas?.flushInk(notify: false)
            model.manifest.pages = to.pages
            model.drawings = to.drawings
            model.orphanedPages.subtract(to.pages.map(\.id))
            model.currentPageIndex = min(to.index, max(0, to.pages.count - 1))
            model.pendingScroll = model.currentPageIndex
            model.registerPageUndo(name, from: to, to: from)
            model.pagesChanged()
        }
        undoManager.setActionName(name)
    }

    // MARK: Ink

    /// Called by the canvas with each page's current ink.
    func inkChanged(_ pages: [UUID: PKDrawing]) {
        var changed: [UUID] = []
        for (id, drawing) in pages where drawings[id]?.strokes.count != drawing.strokes.count || drawings[id]?.bounds != drawing.bounds {
            changed.append(id)
        }
        for id in drawings.keys where pages[id] == nil && !(drawings[id]?.strokes.isEmpty ?? true) { changed.append(id) }
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
        let reference = manifest.pages[safe: index ?? currentPageIndex] ?? manifest.pages.last
        let size = reference?.size ?? .letter
        let page = PageSpec(size: size, paper: paper ?? reference?.paper ?? manifest.defaultPaper)
        let insertAt = min((index ?? currentPageIndex) + 1, manifest.pages.count)
        performPageChange("Add Page") {
            manifest.pages.insert(page, at: insertAt)
            currentPageIndex = insertAt
        }
        pendingScroll = insertAt
        flash("Page \(insertAt + 1) added")
    }

    func duplicatePage(_ index: Int) {
        guard let original = manifest.pages[safe: index] else { return }
        var copy = original
        copy.id = UUID()
        copy.elements = original.elements.map { var e = $0; e.id = UUID(); return e }
        performPageChange("Duplicate Page") {
            manifest.pages.insert(copy, at: index + 1)
            drawings[copy.id] = drawings[original.id]
            if let recognition = recognitionByPage[original.id] { recognitionByPage[copy.id] = recognition }
        }
        pendingScroll = index + 1
    }

    func deletePage(_ index: Int) {
        guard manifest.pages.count > 1, let page = manifest.pages[safe: index] else { return }
        performPageChange("Delete Page") {
            manifest.pages.remove(at: index)
            orphanedPages.insert(page.id)
            currentPageIndex = min(currentPageIndex, manifest.pages.count - 1)
        }
        flash("Page deleted")
    }

    func movePage(from source: IndexSet, to destination: Int) {
        performPageChange("Move Page") {
            manifest.pages.move(fromOffsets: source, toOffset: destination)
        }
    }

    func setPaper(_ paper: PaperRef, forPage index: Int? = nil, allPages: Bool = false) {
        performPageChange("Change Paper") {
            if allPages {
                for i in manifest.pages.indices where manifest.pages[i].source == nil { manifest.pages[i].paper = paper }
                manifest.defaultPaper = paper
            } else if let i = index ?? Optional(currentPageIndex), manifest.pages.indices.contains(i) {
                manifest.pages[i].paper = paper
            }
        }
    }

    func appendDocument(_ url: URL) async {
        canvas?.flushInk()
        do {
            let pdf = try await DocumentImporter.convertToPDF(url)
            var updated = manifest
            let added = try DocumentImporter.appendPDF(pdf, to: package, manifest: &updated)
            performPageChange("Insert Document") { manifest = updated }
            if let first = added.first, let index = manifest.pages.firstIndex(where: { $0.id == first.id }) {
                pendingScroll = index
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func pagesChanged() {
        layoutVersion += 1
        scheduleSave()
    }

    // MARK: Elements

    private func pageIndex(_ pageID: UUID) -> Int? {
        manifest.pages.firstIndex { $0.id == pageID }
    }

    /// Snapshots a page's elements, runs `change`, and registers an undo.
    private func performElementChange(_ name: String, onPage pageID: UUID, _ change: (inout [PageElement]) -> Void) {
        guard let p = pageIndex(pageID) else { return }
        let before = manifest.pages[p].elements
        change(&manifest.pages[p].elements)
        let after = manifest.pages[p].elements
        guard before != after else { return }
        registerElementUndo(name, pageID: pageID, from: after, to: before)
        canvas?.reloadElements(page: p)
        scheduleSave()
    }

    private func registerElementUndo(_ name: String, pageID: UUID, from: [PageElement], to: [PageElement]) {
        undoManager.registerUndo(withTarget: self) { model in
            guard let p = model.pageIndex(pageID) else { return }
            model.manifest.pages[p].elements = to
            model.registerElementUndo(name, pageID: pageID, from: to, to: from)
            model.canvas?.reloadElements(page: p)
            model.scheduleSave()
        }
        undoManager.setActionName(name)
    }

    func addElement(_ element: PageElement, toPage index: Int) {
        guard let page = manifest.pages[safe: index] else { return }
        let name: String
        switch element.kind {
        case .text: name = "Add Text"
        case .sticker: name = "Add Sticker"
        case .image: name = "Add Photo"
        }
        performElementChange(name, onPage: page.id) { $0.append(element) }
    }

    /// Updates an element. Drags and typing pass `undoable: false` and commit once at the end.
    func updateElement(_ element: PageElement, onPage pageID: UUID, undoable: Bool = true) {
        guard let p = pageIndex(pageID), let e = manifest.pages[p].elements.firstIndex(where: { $0.id == element.id }) else { return }
        if undoable {
            let name = element.kind == .text ? "Edit Text" : "Move"
            performElementChange(name, onPage: pageID) { $0[e] = element }
        } else {
            manifest.pages[p].elements[e] = element
            scheduleSave()
        }
    }

    func removeElement(_ id: UUID, onPage pageID: UUID) {
        if selection?.elementID == id { selection = nil }
        performElementChange("Delete", onPage: pageID) { $0.removeAll { $0.id == id } }
    }

    func bringToFront(_ id: UUID, onPage pageID: UUID) {
        performElementChange("Bring to Front", onPage: pageID) { elements in
            if let i = elements.firstIndex(where: { $0.id == id }) { elements.append(elements.remove(at: i)) }
        }
    }

    func sendToBack(_ id: UUID, onPage pageID: UUID) {
        performElementChange("Send to Back", onPage: pageID) { elements in
            if let i = elements.firstIndex(where: { $0.id == id }) { elements.insert(elements.remove(at: i), at: 0) }
        }
    }

    func applyTextStyle(color: String? = nil, fontSize: Double? = nil, alignment: String? = nil, to id: UUID, onPage pageID: UUID) {
        performElementChange("Change Style", onPage: pageID) { elements in
            guard let i = elements.firstIndex(where: { $0.id == id }), var text = elements[i].text else { return }
            if let color { text.color = color }
            if let fontSize { text.fontSize = fontSize }
            if let alignment { text.alignment = alignment }
            elements[i].text = text
            rememberTextStyle(text)
        }
    }

    func rememberTextStyle(_ text: TextContent) {
        textStyle = TextContent(string: "", fontName: text.fontName, fontSize: text.fontSize, color: text.color, alignment: text.alignment)
        if let data = try? NoteJSON.encoder.encode(textStyle) { UserDefaults.standard.set(data, forKey: "textStyle") }
    }

    /// Places an empty text box and returns its id so the canvas can start editing.
    func addText(at point: CGPoint, onPage index: Int) -> UUID? {
        guard let page = manifest.pages[safe: index] else { return nil }
        let width = min(340, max(120, page.size.width - 48))
        let x = min(max(0, point.x), page.size.width - width)
        let element = PageElement.text("", frame: Rect(x: x, y: point.y - 14, width: width, height: 34), style: textStyle)
        addElement(element, toPage: index)
        return element.id
    }

    func addSticker(_ ref: ContentRef) {
        let index = currentPageIndex
        guard let page = manifest.pages[safe: index] else { return }
        let side = min(page.size.width, page.size.height) * 0.2
        let center = canvas?.visibleCenter(onPage: index) ?? CGPoint(x: page.size.width / 2, y: page.size.height / 2)
        var frame = Rect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        if let sticker = catalog.sticker(ref), let canvas = sticker.canvas, canvas.width > canvas.height {
            frame.height = side * canvas.height / canvas.width
            frame.width = side
        }
        let element = PageElement(kind: .sticker, frame: frame, rotation: 0, sticker: ref)
        addElement(element, toPage: index)
        mode = .select
        selection = ElementSelection(pageID: page.id, elementID: element.id)
    }

    /// An emoji sticker from the keyboard, stored as a character so it stays crisp.
    func addEmoji(_ emoji: String) {
        addSticker(ContentRef(packID: EmojiPack.id, itemID: emoji))
    }

    func addImage(_ data: Data) {
        guard let image = UIImage(data: data), let png = image.pngData() ?? image.jpegData(compressionQuality: 0.9) else { return }
        let index = currentPageIndex
        guard let page = manifest.pages[safe: index], let path = try? package.addData(png, into: "media", fileExtension: "png") else { return }
        let width = page.size.width * 0.5
        let height = width * image.size.height / max(image.size.width, 1)
        let center = canvas?.visibleCenter(onPage: index) ?? CGPoint(x: page.size.width / 2, y: page.size.height / 2)
        let element = PageElement(kind: .image, frame: Rect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height), image: path)
        addElement(element, toPage: index)
        mode = .select
        selection = ElementSelection(pageID: page.id, elementID: element.id)
    }

    // MARK: Convert handwriting

    /// Turns the given strokes on a page into a text box, as one undoable step.
    func convertStrokes(_ strokes: [PKStroke], onPage pageID: UUID) async {
        guard let page = manifest.pages.first(where: { $0.id == pageID }), !strokes.isEmpty else { return }
        let drawing = PKDrawing(strokes: strokes)
        let lines = (try? await HandwritingRecognizer.recognize(drawing, pageSize: page.size)) ?? []
        let text = lines.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let bounds = drawing.bounds
        let lineHeight = bounds.height / CGFloat(max(1, lines.count))
        var style = textStyle
        style.fontSize = min(40, max(11, Double(lineHeight) * 0.72))
        let frame = Rect(x: max(0, bounds.minX), y: bounds.minY - 2, width: min(page.size.width - bounds.minX, max(bounds.width + 40, 120)), height: bounds.height + 8)
        replaceInk(removing: strokes, onPage: pageID, with: PageElement.text(text, frame: frame, style: style), name: "Convert to Text")
    }

    /// Replaces the page's whole ink with a text box.
    func replaceInkWithText(_ text: String, onPage pageID: UUID) {
        guard let page = manifest.pages.first(where: { $0.id == pageID }) else { return }
        let strokes = drawing(for: pageID).strokes
        let frame = Rect(x: 60, y: 60, width: page.size.width - 120, height: 200)
        replaceInk(removing: strokes, onPage: pageID, with: PageElement.text(text, frame: frame, style: textStyle), name: "Convert Page to Text")
    }

    private func replaceInk(removing strokes: [PKStroke], onPage pageID: UUID, with element: PageElement, name: String) {
        canvas?.flushInk()
        let removed = Set(strokes.map { StrokeKey($0) })
        let remaining = PKDrawing(strokes: drawing(for: pageID).strokes.filter { !removed.contains(StrokeKey($0)) })
        undoManager.beginUndoGrouping()
        performPageChange(name) {
            drawings[pageID] = remaining
        }
        if let index = pageIndex(pageID) { addElement(element, toPage: index) }
        undoManager.setActionName(name)
        undoManager.endUndoGrouping()
        scheduleRecognition(for: pageID)
    }

    /// Identifies a stroke by its path, since `PKStroke` is not Hashable.
    struct StrokeKey: Hashable {
        let date: Date
        let count: Int
        let start: CGPoint
        init(_ stroke: PKStroke) {
            date = stroke.path.creationDate
            count = stroke.path.count
            start = stroke.path.first?.location ?? .zero
        }
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

    func collaborationDidEnd() {
        undoManager.removeAllActions()
        refreshUndoState()
        layoutVersion += 1
        canvas?.apply()
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
            // Pages deleted and not brought back by undo lose their files now.
            let live = Set(manifest.pages.map(\.id))
            for id in orphanedPages where !live.contains(id) && !undoManager.canUndo {
                package.removePageFiles(id)
                savedInk[id] = nil
                drawings[id] = nil
                orphanedPages.remove(id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Saves and writes the library thumbnail when the note closes.
    func close() {
        recording.shutDown()
        undoManager.removeAllActions()
        save()
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
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != manifest.title else { return }
        manifest.title = trimmed
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
