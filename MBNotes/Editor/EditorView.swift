import NoteEngine
import NoteIntelligence
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
    let package: NotePackage
    var initialPageID: UUID?
    var onClose: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.zoomNamespace) private var zoom
    @State private var model: EditorModel?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let model {
                EditorContent(model: model, initialPageID: initialPageID, onClose: onClose)
            } else if let loadError {
                ContentUnavailableView("Couldn't Open This Note", systemImage: "exclamationmark.triangle", description: Text(loadError))
                    .overlay(alignment: .topLeading) {
                        Button("Close", action: onClose).padding()
                    }
            } else {
                ProgressView()
            }
        }
        .modifier(ZoomTransition(id: package.url, namespace: zoom))
        .task {
            do {
                model = try EditorModel(package: package, catalog: app.catalog)
            } catch {
                loadError = error.localizedDescription
            }
        }
    }
}

/// Zooms the editor out of its library tile when a namespace is available.
private struct ZoomTransition: ViewModifier {
    let id: URL
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            content
        }
    }
}

private struct EditorContent: View {
    @Bindable var model: EditorModel
    var initialPageID: UUID?
    var onClose: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @State private var sheet: EditorSheet?
    @State private var showInspector = false
    @State private var inspectorTab: InspectorTab = .recordings
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var showDocumentPicker = false
    @State private var showScanner = false
    @State private var title = ""
    @State private var renaming = false
    @State private var didSetup = false

    private var compact: Bool { sizeClass == .compact }

    var body: some View {
        NavigationStack {
            NoteCanvasRepresentable(model: model)
                .overlay(alignment: .top) { hud }
                .safeAreaInset(edge: .bottom) {
                    if model.recording.state != .idle || model.recording.playingID != nil {
                        RecordingBar(recording: model.recording) {
                            inspectorTab = .recordings
                            showInspector = true
                        }
                        .frame(maxWidth: 560)
                        .padding(.horizontal, 12)
                        .padding(.bottom, compact && model.mode != .pen ? 4 : 8)
                    }
                }
                .navigationTitle(model.manifest.title.isEmpty ? "Untitled" : model.manifest.title)
                .navigationSubtitle("Page \(model.currentPageIndex + 1) of \(model.pageCount)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarTitleMenu { titleMenu }
                .toolbar { toolbar }
                .toolbar(compact && model.mode == .pen ? .hidden : .visible, for: .bottomBar)
                .inspector(isPresented: $showInspector) {
                    NoteInspector(model: model, tab: $inspectorTab)
                        .inspectorColumnWidth(min: 320, ideal: 380, max: 520)
                }
        }
        .alert("Rename", isPresented: $renaming) {
            TextField("Title", text: $title)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { model.rename(title) }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .pages: PageNavigator(model: model)
            case .paper: PaperSheet(model: model)
            case .stickers: StickerPicker { model.addSticker($0) } onEmoji: { model.addEmoji($0) }
            case .convert: ConvertPageSheet(model: model)
            }
        }
        .onChange(of: sheet) { if sheet == nil { model.canvas?.restoreFirstResponder() } }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) {
            guard let item = photoItem else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { model.addImage(data) }
                photoItem = nil
            }
        }
        .fileImporter(isPresented: $showDocumentPicker, allowedContentTypes: DocumentImporter.supportedTypes) { result in
            guard case .success(let url) = result else { return }
            Task {
                let scoped = url.startAccessingSecurityScopedResource()
                await model.appendDocument(url)
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
        }
        .fullScreenCover(isPresented: $showScanner) {
            DocumentScannerView { url in Task { await model.appendDocument(url) } }
                .ignoresSafeArea()
        }
        .alert("Something Went Wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onChange(of: scenePhase) {
            if scenePhase != .active { model.save() }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: model.hud) { _, new in new != nil }
        .onAppear(perform: setUp)
        .focusedSceneValue(\.editorActions, EditorActions(undo: { model.undo() }, redo: { model.redo() }, setMode: { model.mode = $0 }, deleteSelection: { model.canvas?.deleteSelection() }))
        #if DEBUG
        .task {
            // Screenshot hook: `-scrollToLastPage` jumps to the end after opening.
            guard ProcessInfo.processInfo.arguments.contains("-scrollToLastPage") else { return }
            try? await Task.sleep(for: .seconds(1))
            model.canvas?.scroll(toPage: model.pageCount - 1, animated: false)
        }
        #endif
    }

    private func setUp() {
        guard !didSetup else { return }
        didSetup = true
        // Phones open in View mode so one finger scrolls; a tap on Pen starts writing.
        if compact { model.mode = .view }
        if let pageID = initialPageID, let index = model.manifest.pages.firstIndex(where: { $0.id == pageID }) {
            model.currentPageIndex = index
            model.pendingScroll = index
        }
    }

    private func close() {
        model.close()
        app.refreshLibrary()
        onClose()
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button(action: close) { Label("Back", systemImage: "chevron.left") }
                .keyboardShortcut("w", modifiers: .command)
        }

        if compact {
            compactToolbar
        } else {
            regularToolbar
        }
    }

    @ToolbarContentBuilder private var regularToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            modeButtons
            convertToggle
            insertMenu
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) {
            undoRedo
            recordButton
            Button {
                showInspector.toggle()
            } label: {
                Label("Transcripts and AI", systemImage: "sidebar.trailing")
            }
            moreMenu
        }
    }

    @ToolbarContentBuilder private var compactToolbar: some ToolbarContent {
        if model.mode == .pen {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { model.mode = .view }
            }
        } else {
            ToolbarItemGroup(placement: .primaryAction) {
                undoRedo
                moreMenu
            }
            ToolbarItemGroup(placement: .bottomBar) {
                pagePill
                Spacer()
                modeButtons
                Spacer()
                insertMenu
            }
        }
    }

    /// One toggle per mode; the active one shows its "on" tint.
    private var modeButtons: some View {
        ForEach(EditorMode.allCases) { mode in
            Toggle(isOn: Binding(get: { model.mode == mode }, set: { if $0 { model.mode = mode } })) {
                Label(mode.title, systemImage: mode.systemImage)
            }
            .toggleStyle(.button)
        }
    }

    /// While on, handwriting turns into text a moment after the pen lifts.
    private var convertToggle: some View {
        Toggle(isOn: $model.convertMode) {
            Label("Convert Handwriting", systemImage: model.convertMode ? "character.cursor.ibeam" : "pencil.and.scribble")
        }
        .toggleStyle(.button)
        .onChange(of: model.convertMode) { _, on in
            if on {
                model.mode = .pen
                model.flash("Write, and it turns into text")
            }
        }
    }

    private var insertMenu: some View {
        Menu {
            Button { showPhotoPicker = true } label: { Label("Photo", systemImage: "photo") }
            if DocumentScannerView.isSupported {
                Button { showScanner = true } label: { Label("Scan Document", systemImage: "doc.viewfinder") }
            }
            Button { sheet = .stickers } label: { Label("Sticker or Emoji", systemImage: "face.smiling") }
            Button { model.mode = .text; model.flash("Tap the page to type") } label: { Label("Text Box", systemImage: "textbox") }
            Button { showDocumentPicker = true } label: { Label("PDF or Slides", systemImage: "doc.badge.plus") }
            Divider()
            Button { model.addPage() } label: { Label("Page After This One", systemImage: "plus.rectangle.portrait") }
            Button { model.addPage(after: model.currentPageIndex - 1) } label: { Label("Page Before This One", systemImage: "plus.rectangle.portrait.fill") }
        } label: {
            Label("Insert", systemImage: "plus")
        }
    }

    private var undoRedo: some View {
        Group {
            Button { model.undo() } label: { Label(model.undoTitle.isEmpty ? "Undo" : "Undo \(model.undoTitle)", systemImage: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
                .keyboardShortcut("z", modifiers: .command)
            Button { model.redo() } label: { Label(model.redoTitle.isEmpty ? "Redo" : "Redo \(model.redoTitle)", systemImage: "arrow.uturn.forward") }
                .disabled(!model.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
    }

    private var pagePill: some View {
        Button { sheet = .pages } label: {
            Text("\(model.currentPageIndex + 1) of \(model.pageCount)")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
        }
        .accessibilityLabel("Page \(model.currentPageIndex + 1) of \(model.pageCount)")
    }

    private var recordButton: some View {
        Button {
            Task {
                if model.recording.state.isCapturing { await model.recording.stop() } else { await model.recording.start() }
            }
        } label: {
            Label(model.recording.state.isCapturing ? "Stop Recording" : "Record", systemImage: model.recording.state.isCapturing ? "stop.circle.fill" : "record.circle")
        }
        .tint(.red)
        .disabled(!(model.recording.state == .idle || model.recording.state.isCapturing))
    }

    private var moreMenu: some View {
        Menu {
            if compact {
                Section {
                    recordButton
                    Button { showInspector.toggle() } label: { Label("Transcripts and AI", systemImage: "sparkles") }
                    convertToggle
                }
            }
            Section {
                Button { title = model.manifest.title; renaming = true } label: { Label("Rename…", systemImage: "pencil") }
                Toggle(isOn: $model.shapeSnapping) { Label("Snap Shapes", systemImage: "square.on.circle") }
                Toggle(isOn: $model.fingerDrawing) { Label("Draw with Finger", systemImage: "hand.draw") }
            }
            Section {
                Button { sheet = .pages } label: { Label("All Pages", systemImage: "square.grid.2x2") }
                Button { sheet = .paper } label: { Label("Paper…", systemImage: "doc.richtext") }
                Button { sheet = .convert } label: { Label("Convert Page to Text…", systemImage: "character.textbox") }
            }
            Section {
                Button { model.canvas?.zoomToFit(animated: true) } label: { Label("Fit Page", systemImage: "arrow.down.right.and.arrow.up.left") }
                    .keyboardShortcut("0", modifiers: .command)
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
    }

    @ViewBuilder private var titleMenu: some View {
        Button { title = model.manifest.title; renaming = true } label: { Label("Rename…", systemImage: "pencil") }
        Button { sheet = .pages } label: { Label("All Pages", systemImage: "square.grid.2x2") }
        Picker("Pages", selection: $model.pageAxis) {
            Label("Side by Side", systemImage: "rectangle.split.2x1").tag(PageLayout.Axis.horizontal)
            Label("Continuous", systemImage: "rectangle.split.1x2").tag(PageLayout.Axis.vertical)
        }
        Button { sheet = .paper } label: { Label("Paper…", systemImage: "doc.richtext") }
        Menu {
            ShareLink(item: NotePDFExport(package: model.package, catalog: app.catalog), preview: SharePreview(model.manifest.title)) {
                Label("PDF", systemImage: "doc.richtext")
            }
            ShareLink(item: NotePDFExport(package: model.package, catalog: app.catalog, includeTranscripts: true), preview: SharePreview(model.manifest.title)) {
                Label("PDF with Transcripts", systemImage: "text.document")
            }
            ShareLink(item: NoteArchiveExport(package: model.package), preview: SharePreview(model.manifest.title)) {
                Label("MB Notes File", systemImage: "doc.zipper")
            }
            if !model.manifest.recordings.isEmpty {
                ShareLink(item: NoteArchiveExport(package: model.package, includeRecordings: false), preview: SharePreview(model.manifest.title)) {
                    Label("MB Notes File Without Recordings", systemImage: "doc.zipper")
                }
            }
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }

    private var hud: some View {
        Group {
            if let message = model.hud {
                Text(message)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.top, 8)
        .animation(.snappy, value: model.hud)
        .allowsHitTesting(false)
    }
}

enum EditorSheet: String, Identifiable {
    case pages, paper, stickers, convert
    var id: String { rawValue }
}

/// What the focused editor can do, for menu-bar commands.
struct EditorActions {
    var undo: () -> Void
    var redo: () -> Void
    var setMode: (EditorMode) -> Void
    var deleteSelection: () -> Void
}

extension FocusedValues {
    @Entry var editorActions: EditorActions?
}

struct NoteCanvasRepresentable: UIViewControllerRepresentable {
    let model: EditorModel
    @Environment(\.theme) private var theme

    func makeUIViewController(context: Context) -> NoteCanvasController {
        let controller = NoteCanvasController(model: model)
        model.canvas = controller
        return controller
    }

    func updateUIViewController(_ controller: NoteCanvasController, context: Context) {
        // Reading these registers observation so SwiftUI calls back when they change.
        _ = model.layoutVersion
        _ = model.mode
        _ = model.convertMode
        _ = model.fingerDrawing
        _ = model.shapeSnapping
        _ = model.pageAxis
        _ = model.pendingScroll
        _ = model.selection
        controller.view.tintColor = UIColor(theme.accent)
        controller.view.backgroundColor = UIColor(theme.canvasBackdrop)
        controller.updateGestureSettings()
        controller.apply()
    }
}
