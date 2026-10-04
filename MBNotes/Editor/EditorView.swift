import NoteEngine
import NoteIntelligence
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
    let package: NotePackage
    @Environment(AppModel.self) private var app
    @State private var model: EditorModel?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let model {
                EditorContent(model: model)
            } else if let loadError {
                ContentUnavailableView("Couldn't open this note", systemImage: "exclamationmark.triangle", description: Text(loadError))
                    .overlay(alignment: .topLeading) {
                        Button("Close") { app.openNote = nil }.padding()
                    }
            } else {
                ProgressView()
            }
        }
        .task {
            do {
                model = try EditorModel(package: package, catalog: app.catalog)
            } catch {
                loadError = error.localizedDescription
            }
        }
    }
}

private struct EditorContent: View {
    @Bindable var model: EditorModel
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var sheet: EditorSheet?
    @State private var showInspector = false
    @State private var inspectorTab: InspectorTab = .recordings
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var showDocumentPicker = false
    @State private var shareItem: ShareItem?
    @State private var renaming = false
    @State private var newTitle = ""
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var compact: Bool { sizeClass == .compact }

    var body: some View {
        NoteCanvasRepresentable(model: model)
            .ignoresSafeArea()
            // An overlay can't change the canvas's size, however wide the chrome gets.
            .overlay {
                VStack(spacing: 8) {
                    topBar
                    if compact {
                        HStack {
                            ScrollView(.horizontal, showsIndicators: false) { toolSwitcher.padding(2) }
                            pageButton
                        }
                    }
                    Spacer()
                    bottomBar
                        // The tool picker docks along the bottom on iPhone.
                        .padding(.bottom, compact && model.tool == .draw ? 96 : 0)
                }
                .padding(.horizontal, 12)
            }
        .inspector(isPresented: $showInspector) {
            NoteInspector(model: model, tab: $inspectorTab)
                .inspectorColumnWidth(min: 320, ideal: 380, max: 520)
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .pages: PageNavigator(model: model)
            case .paper: PaperSheet(model: model)
            case .stickers: StickerPicker { model.addSticker($0) }
            case .convert: ConvertHandwritingSheet(model: model)
            }
        }
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
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .alert("Rename", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { model.rename(newTitle) }
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onChange(of: scenePhase) {
            if scenePhase != .active { model.save() }
        }
        #if DEBUG
        .task {
            // Screenshot hook: `-scrollToLastPage` jumps to the end after opening.
            guard ProcessInfo.processInfo.arguments.contains("-scrollToLastPage") else { return }
            try? await Task.sleep(for: .seconds(1))
            model.canvas?.scroll(toPage: model.pageCount - 1, animated: false)
        }
        #endif
    }

    // MARK: Top bar

    private var topBar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    model.close()
                    app.refreshLibrary()
                    app.openNote = nil
                } label: {
                    Image(systemName: "chevron.left").font(.body.weight(.semibold)).frame(width: 34, height: 34)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Close note")

                Button {
                    newTitle = model.manifest.title
                    renaming = true
                } label: {
                    Text(model.manifest.title.isEmpty ? "Untitled" : model.manifest.title)
                        .font(.headline)
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                }
                .buttonStyle(.glass)
                .layoutPriority(1)

                Spacer(minLength: 0)

                if !compact {
                    toolSwitcher
                    Spacer(minLength: 0)
                    undoRedo
                }

                recordButton

                Button {
                    inspectorTab = .ai
                    showInspector.toggle()
                } label: {
                    Image(systemName: "sparkles").frame(width: 34, height: 34)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Transcripts and AI")

                moreMenu
            }
        }
        .padding(.top, 4)
    }

    /// On iPhone, PencilKit's own tool picker carries undo and redo.
    private var undoRedo: some View {
        HStack(spacing: 4) {
            Button { model.canvas?.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 30, height: 30) }
                .accessibilityLabel("Undo")
            Button { model.canvas?.redo() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 30, height: 30) }
                .accessibilityLabel("Redo")
        }
        .buttonStyle(.glass)
    }

    private var pageButton: some View {
        Button { sheet = .pages } label: {
            Text("\(model.currentPageIndex + 1) / \(model.pageCount)")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .padding(.horizontal, 14)
                .frame(height: 36)
        }
        .buttonStyle(.glass)
        .accessibilityLabel("Page \(model.currentPageIndex + 1) of \(model.pageCount)")
    }

    private var toolSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(EditorTool.allCases) { tool in
                Button {
                    model.tool = tool
                } label: {
                    Image(systemName: tool.systemImage)
                        .font(.body.weight(.semibold))
                        .frame(width: 40, height: 34)
                        .foregroundStyle(model.tool == tool ? .white : .primary)
                        .background {
                            if model.tool == tool {
                                Capsule().fill(Brand.gradient)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tool.title)
            }
            Divider().frame(height: 22).padding(.horizontal, 4)
            Button { sheet = .stickers } label: {
                Image(systemName: "face.smiling").frame(width: 36, height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stickers")
            Button { showPhotoPicker = true } label: {
                Image(systemName: "photo").frame(width: 36, height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Insert photo")
            Button { model.shapeSnapping.toggle() } label: {
                Image(systemName: model.shapeSnapping ? "square.on.circle.fill" : "square.on.circle")
                    .foregroundStyle(model.shapeSnapping ? Brand.pink : .primary)
                    .frame(width: 36, height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.shapeSnapping ? "Shape snapping on" : "Shape snapping off")
            Button { model.fingerDrawing.toggle() } label: {
                Image(systemName: model.fingerDrawing ? "hand.draw.fill" : "hand.draw")
                    .foregroundStyle(model.fingerDrawing ? Brand.pink : .primary)
                    .frame(width: 36, height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.fingerDrawing ? "Finger drawing on" : "Finger drawing off")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private var recordButton: some View {
        Button {
            Task {
                if model.recording.state == .recording { await model.recording.stop() } else { await model.recording.start() }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.recording.state == .recording ? "stop.fill" : "record.circle")
                if model.recording.state == .recording {
                    Text(Duration.seconds(model.recording.elapsed).formatted(.time(pattern: .minuteSecond)))
                        .monospacedDigit()
                }
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(model.recording.state == .recording ? .white : Color.red)
            .frame(height: 34)
            .padding(.horizontal, model.recording.state == .recording ? 10 : 2)
        }
        .buttonStyle(.glass)
        .tint(model.recording.state == .recording ? .red : nil)
        .disabled(!(model.recording.state == .idle || model.recording.state == .recording))
        .accessibilityLabel(model.recording.state == .recording ? "Stop recording" : "Record")
    }

    private var moreMenu: some View {
        Menu {
            Section("Pages") {
                Button { model.addPage() } label: { Label("Add page", systemImage: "plus.rectangle.portrait") }
                Button { sheet = .pages } label: { Label("All pages", systemImage: "square.grid.2x2") }
                Button { sheet = .paper } label: { Label("Paper", systemImage: "doc.richtext") }
                Button { showDocumentPicker = true } label: { Label("Insert PDF or slides", systemImage: "doc.badge.plus") }
            }
            Section("Text") {
                Button { sheet = .convert } label: { Label("Convert handwriting to text", systemImage: "character.textbox") }
            }
            Section("Share") {
                Button {
                    Task { if let url = await model.exportPDF(includeTranscripts: false) { shareItem = ShareItem(url: url) } }
                } label: { Label("Export searchable PDF", systemImage: "doc.text.magnifyingglass") }
                Button {
                    Task { if let url = await model.exportPDF(includeTranscripts: true) { shareItem = ShareItem(url: url) } }
                } label: { Label("Export PDF with transcripts", systemImage: "text.document") }
                Button {
                    if let url = model.exportPackage() { shareItem = ShareItem(url: url) }
                } label: { Label("Share MB Notes file", systemImage: "square.and.arrow.up") }
            }
        } label: {
            Image(systemName: "ellipsis").frame(width: 34, height: 34)
        }
        .buttonStyle(.glass)
        .accessibilityLabel("More")
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(alignment: .bottom) {
            if !compact { pageButton }

            Spacer()

            if model.recording.state != .idle || model.recording.playingID != nil {
                RecordingBar(recording: model.recording) {
                    inspectorTab = .recordings
                    showInspector = true
                }
                .frame(maxWidth: 520)
            }

            Spacer()

            Button { model.addPage() } label: {
                Image(systemName: "plus").font(.body.weight(.bold)).frame(width: 36, height: 36)
            }
            .buttonStyle(.glassProminent)
            .accessibilityLabel("Add page")
        }
        .padding(.bottom, 8)
    }
}

enum EditorSheet: String, Identifiable {
    case pages, paper, stickers, convert
    var id: String { rawValue }
}

struct ShareItem: Identifiable {
    let url: URL
    var id: URL { url }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct NoteCanvasRepresentable: UIViewControllerRepresentable {
    let model: EditorModel

    func makeUIViewController(context: Context) -> NoteCanvasController {
        let controller = NoteCanvasController(model: model)
        model.canvas = controller
        return controller
    }

    func updateUIViewController(_ controller: NoteCanvasController, context: Context) {
        // Reading these registers observation so SwiftUI calls back when they change.
        _ = model.layoutVersion
        _ = model.tool
        _ = model.fingerDrawing
        _ = model.shapeSnapping
        controller.apply()
    }
}
