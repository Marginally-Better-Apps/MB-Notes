import NoteEngine
import PencilKit
import SwiftUI

/// Page thumbnails: jump, reorder, duplicate, and delete.
struct PageNavigator: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var thumbnails: [UUID: UIImage] = [:]
    @State private var editMode = EditMode.inactive

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(model.manifest.pages.enumerated()), id: \.element.id) { index, page in
                    row(index: index, page: page)
                }
                .onMove { model.movePage(from: $0, to: $1) }
                .onDelete { offsets in
                    for index in offsets.sorted(by: >) { model.deletePage(index) }
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle("Pages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(editMode == .active ? "Done" : "Edit") { withAnimation { editMode = editMode == .active ? .inactive : .active } }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done", role: .confirm) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { model.addPage(after: model.pageCount - 1) } label: { Label("Add Page", systemImage: "plus") }
                }
            }
        }
    }

    private func row(index: Int, page: PageSpec) -> some View {
        let current = index == model.currentPageIndex
        return Button {
            model.canvas?.scroll(toPage: index)
            dismiss()
        } label: {
            HStack(spacing: 16) {
                thumbnail(page)
                    .frame(height: 96)
                    .clipShape(.rect(cornerRadius: Radius.thumb))
                    .overlay(RoundedRectangle(cornerRadius: Radius.thumb).strokeBorder(.separator, lineWidth: 0.5))
                    .overlay(RoundedRectangle(cornerRadius: Radius.thumb + 3).stroke(.tint, lineWidth: current ? 2.5 : 0).padding(-3))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Page \(index + 1)")
                    Text(model.catalog.resolvePaper(page.paper.template, embedded: model.manifest.embedded).name)
                        .font(.subheadline).foregroundStyle(.secondary)
                    if current { Text("Current").font(.caption).foregroundStyle(.tint) }
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { model.deletePage(index) } label: { Label("Delete", systemImage: "trash") }
                .disabled(model.pageCount <= 1)
        }
        .swipeActions(edge: .leading) {
            Button { model.duplicatePage(index) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                .tint(.accentColor)
        }
        .contextMenu {
            Button { model.duplicatePage(index) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Button { model.addPage(after: index - 1) } label: { Label("Insert Page Before", systemImage: "arrow.up.doc") }
            Button { model.addPage(after: index) } label: { Label("Insert Page After", systemImage: "arrow.down.doc") }
            Button { model.movePage(from: [index], to: 0) } label: { Label("Move to Start", systemImage: "arrow.up.to.line") }
            Button { model.movePage(from: [index], to: model.pageCount) } label: { Label("Move to End", systemImage: "arrow.down.to.line") }
            Divider()
            Button(role: .destructive) { model.deletePage(index) } label: { Label("Delete", systemImage: "trash") }
                .disabled(model.pageCount <= 1)
        } preview: {
            thumbnail(page).frame(width: 240)
        }
        .task(id: model.pageRevision(page.id)) {
            let renderer = model.renderer
            let ink = model.drawing(for: page.id)
            thumbnails[page.id] = await Task.detached { renderer.image(for: page, width: 240, ink: ink) }.value
        }
    }

    @ViewBuilder private func thumbnail(_ page: PageSpec) -> some View {
        if let image = thumbnails[page.id] {
            Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
        } else {
            Rectangle().fill(.quaternary).aspectRatio(page.size.width / page.size.height, contentMode: .fit)
        }
    }
}

/// Change the paper for this page or the whole note, and tune template parameters.
struct PaperSheet: View {
    let model: EditorModel
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var selection = ContentRef.blankPaper
    @State private var parameters: [String: Double] = [:]
    @State private var scope = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Apply To", selection: $scope) {
                        Text("This Page").tag(0)
                        Text("All Pages").tag(1)
                    }
                    .pickerStyle(.segmented)
                }
                let template = model.catalog.resolvePaper(selection, embedded: model.manifest.embedded)
                if !template.parameters.isEmpty {
                    Section(template.name) {
                        ForEach(template.parameters.keys.sorted(), id: \.self) { key in
                            let parameter = template.parameters[key]!
                            VStack(alignment: .leading) {
                                Text("\(parameter.label): \(Int(parameters[key] ?? parameter.defaultValue))").font(.subheadline)
                                Slider(value: Binding(get: { parameters[key] ?? parameter.defaultValue }, set: { parameters[key] = $0 }),
                                       in: (parameter.minimum ?? 0)...(parameter.maximum ?? 100), step: parameter.step ?? 1)
                            }
                        }
                    }
                }
                Section("Paper") {
                    PaperGrid(selection: $selection, accent: model.manifest.accentColor, parameters: parameters)
                        .padding(.vertical, 4)
                }
            }
            .navigationTitle("Paper")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply", role: .confirm) {
                        let paper = PaperRef(template: selection, parameters: parameters)
                        model.setPaper(paper, allPages: scope == 1)
                        app.preferredPaper = paper
                        dismiss()
                    }
                }
            }
            .onAppear {
                let page = model.manifest.pages[safe: model.currentPageIndex]
                selection = page?.paper.template ?? model.manifest.defaultPaper.template
                parameters = page?.paper.parameters ?? [:]
            }
            .onChange(of: selection) { parameters = [:] }
        }
    }
}

/// Recognizes the whole page's handwriting and offers to replace it with typed text.
struct ConvertPageSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isWorking = true

    var body: some View {
        NavigationStack {
            Group {
                if isWorking {
                    ProgressView("Reading your handwriting…")
                } else if text.isEmpty {
                    ContentUnavailableView("No Handwriting Found", systemImage: "scribble", description: Text("Write on this page, then try again."))
                } else {
                    TextEditor(text: $text)
                        .padding()
                }
            }
            .navigationTitle("Convert Page to Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu("Use") {
                        Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: "doc.on.doc") }
                        Button {
                            let index = model.currentPageIndex
                            if let page = model.manifest.pages[safe: index] {
                                model.addElement(.text(text, frame: Rect(x: 60, y: 60, width: page.size.width - 120, height: 200), style: model.textStyle), toPage: index)
                            }
                            dismiss()
                        } label: { Label("Add as Text Box", systemImage: "textbox") }
                        Button {
                            if let page = model.manifest.pages[safe: model.currentPageIndex] {
                                model.replaceInkWithText(text, onPage: page.id)
                            }
                            dismiss()
                        } label: { Label("Replace Handwriting with Text", systemImage: "arrow.triangle.2.circlepath") }
                    }
                    .disabled(text.isEmpty)
                }
            }
            .task {
                model.canvas?.flushInk()
                guard let page = model.manifest.pages[safe: model.currentPageIndex] else { return }
                await model.recognize(page.id)
                text = model.recognitionByPage[page.id]?.text ?? ""
                isWorking = false
            }
        }
    }
}

/// Browse every sticker from every installed pack, or type any emoji.
struct StickerPicker: View {
    var onPick: (ContentRef) -> Void
    var onEmoji: (String) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @AppStorage("recentStickers") private var recentRaw = ""
    @State private var query = ""
    @State private var showingKeyboard = false

    private var recent: [ContentRef] {
        recentRaw.split(separator: "\n").compactMap { ContentRef(rawValue: String($0)) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                let stickers = app.catalog.allStickers.filter { entry in
                    query.isEmpty || entry.sticker.name.localizedCaseInsensitiveContains(query) || entry.sticker.tags.contains { $0.localizedCaseInsensitiveContains(query) }
                }
                let categories = stickers.map(\.sticker.category).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                VStack(alignment: .leading, spacing: 18) {
                    if query.isEmpty {
                        Button { showingKeyboard = true } label: {
                            Label("Any Emoji", systemImage: "keyboard")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        if !recent.isEmpty {
                            section("Recent", stickers: recent)
                        }
                    }
                    ForEach(categories, id: \.self) { category in
                        section(category, stickers: stickers.filter { $0.sticker.category == category }.map(\.ref))
                    }
                    if stickers.isEmpty && !query.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                    Link(destination: URL(string: "https://github.com/Marginally-Better-Apps/MB-Notes/blob/main/docs/PACKS.md")!) {
                        Label("Get More Stickers", systemImage: "shippingbox")
                    }
                    .font(.footnote)
                    .frame(maxWidth: .infinity)
                }
                .padding(20)
            }
            .searchable(text: $query, prompt: "Search Stickers")
            .navigationTitle("Stickers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", role: .confirm) { dismiss() } }
            }
            .background {
                // Off-screen field that brings up the system emoji keyboard.
                EmojiKeyboardField(isActive: $showingKeyboard) { emoji in
                    remember(ContentRef(packID: EmojiPack.id, itemID: emoji))
                    onEmoji(emoji)
                    dismiss()
                }
                .frame(width: 1, height: 1)
                .opacity(0.01)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func section(_ title: String, stickers: [ContentRef]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 60), spacing: 10)], spacing: 10) {
                ForEach(stickers, id: \.self) { ref in
                    Button {
                        remember(ref)
                        onPick(ref)
                        dismiss()
                    } label: {
                        StickerView(ref: ref, catalog: app.catalog)
                            .frame(width: 52, height: 52)
                            .padding(6)
                            .background(.fill.quaternary, in: .rect(cornerRadius: Radius.tile))
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                    .accessibilityLabel(Text(app.catalog.sticker(ref)?.name ?? ref.itemID))
                }
            }
        }
    }

    private func remember(_ ref: ContentRef) {
        var list = recent.filter { $0 != ref }
        list.insert(ref, at: 0)
        recentRaw = list.prefix(24).map(\.rawValue).joined(separator: "\n")
    }
}

/// A hidden text field that opens the system emoji keyboard and reports each emoji typed.
struct EmojiKeyboardField: UIViewRepresentable {
    @Binding var isActive: Bool
    var onEmoji: (String) -> Void

    func makeUIView(context: Context) -> EmojiTextField {
        let field = EmojiTextField()
        field.delegate = context.coordinator
        field.autocorrectionType = .no
        return field
    }

    func updateUIView(_ field: EmojiTextField, context: Context) {
        context.coordinator.parent = self
        if isActive, !field.isFirstResponder {
            field.becomeFirstResponder()
        } else if !isActive, field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: EmojiKeyboardField
        init(parent: EmojiKeyboardField) { self.parent = parent }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            let isEmoji = string.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.properties.isEmojiModifier || $0.value == 0xFE0F || $0.value == 0x200D }
            if isEmoji { parent.onEmoji(string) }
            return false
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.isActive = false
        }
    }
}

/// Prefers the emoji keyboard; falls back to the default keyboard if it is disabled.
final class EmojiTextField: UITextField {
    override var textInputContextIdentifier: String? { "mbnotes.emoji" }

    override var textInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" } ?? super.textInputMode
    }
}
