import NoteEngine
import SwiftUI
import UniformTypeIdentifiers

/// One folder of the library as a gallery or list, with search, selection, and creation.
struct FolderView: View {
    let folder: URL
    @Environment(AppModel.self) private var app
    @Environment(SceneModel.self) private var scene
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.zoomNamespace) private var zoom
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("libraryLayout") private var layoutRaw = LibraryLayout.gallery.rawValue
    @AppStorage("librarySort") private var sortRaw = LibrarySort.modified.rawValue
    @State private var items: [LibraryEntry] = []
    @State private var query = ""
    @State private var searchScope = SearchScope.all
    @State private var searchResults: [SearchResult] = []
    @State private var sheet: Sheet?
    @State private var renaming: LibraryEntry?
    @State private var newName = ""
    @State private var showImporter = false
    @State private var showScanner = false
    @State private var editMode = EditMode.inactive
    @State private var selection = Set<URL>()
    @State private var dropTarget: URL?
    @State private var folderToDelete: LibraryEntry?
    @State private var createdCount = 0
    @State private var deletedCount = 0
    @ScaledMetric private var tileWidth: CGFloat = 150

    enum Sheet: Identifiable {
        case newNotebook, newFolder
        case editFolder(LibraryEntry)
        case move([LibraryEntry])

        var id: String {
            switch self {
            case .newNotebook: return "notebook"
            case .newFolder: return "folder"
            case .editFolder(let item): return "edit-\(item.url.path)"
            case .move(let items): return "move-" + items.map(\.url.path).joined()
            }
        }
    }

    private var isRoot: Bool { app.library.relativePath(of: folder)?.isEmpty ?? true }
    private var title: String { isRoot ? "All Notes" : folder.lastPathComponent }
    private var compact: Bool { sizeClass == .compact }
    private var layout: LibraryLayout {
        dynamicTypeSize.isAccessibilitySize ? .list : (LibraryLayout(rawValue: layoutRaw) ?? .gallery)
    }
    private var isEditing: Bool { editMode == .active }
    private var pinned: [LibraryEntry] { items.filter { !$0.isFolder && $0.isPinned } }
    private var folders: [LibraryEntry] { items.filter(\.isFolder) }
    private var notes: [LibraryEntry] { items.filter { !$0.isFolder && !$0.isPinned } }

    var body: some View {
        content
            .navigationTitle(title)
            .toolbarTitleDisplayMode(isRoot ? .large : .inlineLarge)
            .toolbarTitleMenu { if !isRoot { titleMenu } }
            .searchable(text: $query, placement: .automatic, prompt: "Search")
            .searchScopes($searchScope, activation: .onSearchPresentation) {
                ForEach(SearchScope.allCases) { Text($0.title).tag($0) }
            }
            .task(id: "\(query)|\(searchScope.rawValue)") {
                guard !query.isEmpty else { searchResults = []; return }
                try? await Task.sleep(for: .milliseconds(250))
                let library = app.library
                let scope = searchScope == .folder ? folder : nil
                let q = query
                let results = try? await Task.detached(priority: .userInitiated) { try await SearchIndex.search(q, in: library, folder: scope) }.value
                if !Task.isCancelled { searchResults = results ?? [] }
            }
            .toolbar { toolbar }
            .environment(\.editMode, $editMode)
            .task(id: app.libraryVersion) { reload() }
            .onChange(of: sortRaw) { reload() }
            .onChange(of: editMode) { if !isEditing { selection = [] } }
            .focusedSceneValue(\.libraryActions, LibraryActions(
                newNote: createQuickNote, newNotebook: { sheet = .newNotebook }, newFolder: { sheet = .newFolder },
                importFiles: { showImporter = true }, scan: { showScanner = true }, setLayout: { layoutRaw = $0.rawValue }))
            .sensoryFeedback(.success, trigger: createdCount)
            .sensoryFeedback(.warning, trigger: deletedCount)
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case .newNotebook: NotebookSheet(folder: folder)
                case .newFolder: FolderEditorSheet(parent: folder, editing: nil)
                case .editFolder(let item): FolderEditorSheet(parent: folder, editing: item)
                case .move(let items): MoveSheet(items: items)
                }
            }
            .fullScreenCover(isPresented: $showScanner) {
                DocumentScannerView { url in Task { await scene.importFiles([url], into: folder) } }
                    .ignoresSafeArea()
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: DocumentImporter.supportedTypes + [.mbNote, .mbNoteArchive, .mbPack, .zip], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { Task { await scene.importFiles(urls, into: folder) } }
            }
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Rename") {
                    if let item = renaming {
                        do { try app.library.rename(item.url, to: newName) } catch { scene.show(error) }
                        app.refreshLibrary()
                    }
                    renaming = nil
                }
            }
            .confirmationDialog(deleteFolderTitle, isPresented: Binding(get: { folderToDelete != nil }, set: { if !$0 { folderToDelete = nil } }), titleVisibility: .visible) {
                Button("Delete Folder", role: .destructive) {
                    if let item = folderToDelete { delete([item], confirmed: true) }
                }
            } message: {
                Text("Its notes move to Recently Deleted for 30 days.")
            }
    }

    private var deleteFolderTitle: String {
        guard let item = folderToDelete else { return "" }
        let count = item.itemCount ?? 0
        return "Delete “\(item.name)” and its \(count) \(count == 1 ? "item" : "items")?"
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if !query.isEmpty {
            SearchResultsList(results: searchResults, query: query)
        } else if items.isEmpty {
            emptyState
        } else if layout == .list {
            list
        } else {
            gallery
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Notes", systemImage: "note.text")
        } description: {
            Text("Start writing, or import a PDF or slide deck to write on.")
        } actions: {
            Button("New Note", action: createQuickNote).buttonStyle(.borderedProminent)
            Button("Import…") { showImporter = true }
        }
        .dropDestination(for: URL.self, action: handleDrop)
    }

    private var gallery: some View {
        ScrollView {
            let columns = compact
                ? [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
                : [GridItem(.adaptive(minimum: tileWidth * 0.9, maximum: tileWidth * 1.15), spacing: 20, alignment: .top)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: compact ? 16 : 24) {
                if !pinned.isEmpty {
                    gridHeader("Pinned")
                    ForEach(pinned) { tile(for: $0) }
                }
                if !folders.isEmpty {
                    gridHeader("Folders")
                    ForEach(folders) { tile(for: $0) }
                }
                if !notes.isEmpty {
                    if !pinned.isEmpty || !folders.isEmpty { gridHeader("Notes") }
                    ForEach(notes) { tile(for: $0) }
                }
            }
            .padding(.horizontal, compact ? 16 : 20)
            .padding(.vertical, 12)
        }
        .dropDestination(for: URL.self, action: handleDrop)
    }

    private func gridHeader(_ text: String) -> some View {
        Section {} header: {
            Text(text).font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
        }
    }

    private var list: some View {
        List(selection: $selection) {
            if !pinned.isEmpty {
                Section("Pinned") { ForEach(pinned) { row(for: $0) } }
            }
            if !folders.isEmpty {
                Section("Folders") { ForEach(folders) { row(for: $0) } }
            }
            if sortRaw == LibrarySort.modified.rawValue {
                ForEach(LibraryDateGroup.group(notes)) { group in
                    Section(group.title) { ForEach(group.items) { row(for: $0) } }
                }
            } else if !notes.isEmpty {
                Section("Notes") { ForEach(notes) { row(for: $0) } }
            }
        }
        .dropDestination(for: URL.self, action: handleDrop)
    }

    // MARK: Items

    @ViewBuilder private func tile(for item: LibraryEntry) -> some View {
        let selected = selection.contains(item.url)
        Button {
            if isEditing {
                toggleSelection(item)
            } else if item.isFolder {
                scene.openNote = nil
                navigate(to: item.url)
            } else {
                scene.open(item.url)
            }
        } label: {
            Group {
                if item.isFolder {
                    FolderTile(item: item, highlighted: dropTarget == item.url)
                } else {
                    NoteTile(item: item, selected: selected)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .modifier(MatchedSource(id: item.url, namespace: zoom))
        .hoverEffect(.lift)
        .draggable(item.url)
        .contextMenu {
            LibraryItemMenu(item: item, actions: actions)
        } preview: {
            if item.isFolder { FolderTile(item: item).padding().frame(width: 200) } else { NoteThumbnail(item: item).frame(width: 220) }
        }
        .modifier(FolderDrop(item: item, dropTarget: $dropTarget, onDrop: handleDrop(into:_:)))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private func row(for item: LibraryEntry) -> some View {
        Group {
            if item.isFolder {
                Button { navigate(to: item.url) } label: { FolderRow(item: item) }
            } else {
                Button { scene.open(item.url) } label: { NoteRow(item: item) }
                    .modifier(MatchedSource(id: item.url, namespace: zoom))
            }
        }
        .buttonStyle(.plain)
        .tag(item.url)
        .draggable(item.url)
        .contextMenu { LibraryItemMenu(item: item, actions: actions) }
        .modifier(FolderDrop(item: item, dropTarget: $dropTarget, onDrop: handleDrop(into:_:)))
        .listRowBackground(dropTarget == item.url ? Color.accentColor.opacity(0.15) : nil)
        .swipeActions(edge: .leading) {
            if !item.isFolder {
                Button { app.togglePinned(item) } label: { Label(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin") }
                    .tint(.orange)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { delete([item]) } label: { Label("Delete", systemImage: "trash") }
            Button { sheet = .move([item]) } label: { Label("Move", systemImage: "folder") }
        }
    }

    /// Accepts dropped notes and folders, highlighting the folder while hovering.
    private struct FolderDrop: ViewModifier {
        let item: LibraryEntry
        @Binding var dropTarget: URL?
        let onDrop: (URL, [URL]) -> Bool

        func body(content: Content) -> some View {
            if item.isFolder {
                content.dropDestination(for: URL.self) { urls, _ in
                    onDrop(item.url, urls)
                } isTargeted: { dropTarget = $0 ? item.url : nil }
            } else {
                content
            }
        }
    }

    private var actions: LibraryItemActions {
        LibraryItemActions(
            rename: { item in newName = item.name; renaming = item },
            customize: { item in sheet = .editFolder(item) },
            move: { items in sheet = .move(items) },
            delete: { items in delete(items) }
        )
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if isEditing {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { withAnimation { editMode = .inactive } }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button { sheet = .move(selectedItems) } label: { Label("Move", systemImage: "folder") }
                    .disabled(selection.isEmpty)
                Spacer()
                Text(selection.isEmpty ? "Select Items" : "\(selection.count) Selected").font(.footnote)
                Spacer()
                Button(role: .destructive) { delete(selectedItems) } label: { Label("Delete", systemImage: "trash") }
                    .disabled(selection.isEmpty)
            }
        } else {
            ToolbarItem(placement: .primaryAction) { optionsMenu }
            if compact {
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) { newNoteButton }
            } else {
                ToolbarItem(placement: .primaryAction) { newNoteButton }
            }
        }
    }

    /// One tap starts a note with the last-used paper; hold for everything else.
    private var newNoteButton: some View {
        Menu {
            Button { sheet = .newNotebook } label: { Label("New Notebook…", systemImage: "book.closed") }
            Button { sheet = .newFolder } label: { Label("New Folder", systemImage: "folder.badge.plus") }
            Divider()
            if DocumentScannerView.isSupported {
                Button { showScanner = true } label: { Label("Scan Documents", systemImage: "doc.viewfinder") }
            }
            Button { showImporter = true } label: { Label("Import…", systemImage: "square.and.arrow.down") }
        } label: {
            Label("New Note", systemImage: "square.and.pencil")
        } primaryAction: {
            createQuickNote()
        }
    }

    private var optionsMenu: some View {
        Menu {
            Button { withAnimation { editMode = .active } } label: { Label("Select", systemImage: "checkmark.circle") }
            Divider()
            Picker("Layout", selection: $layoutRaw) {
                Label("Gallery", systemImage: "square.grid.2x2").tag(LibraryLayout.gallery.rawValue)
                Label("List", systemImage: "list.bullet").tag(LibraryLayout.list.rawValue)
            }
            .pickerStyle(.inline)
            Menu {
                Picker("Sort By", selection: $sortRaw) {
                    Text("Date Edited").tag(LibrarySort.modified.rawValue)
                    Text("Date Created").tag(LibrarySort.created.rawValue)
                    Text("Title").tag(LibrarySort.name.rawValue)
                }
            } label: {
                Label("Sort By", systemImage: "arrow.up.arrow.down")
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
    }

    @ViewBuilder private var titleMenu: some View {
        if let entry = app.library.item(at: folder) {
            Button { newName = entry.name; renaming = entry } label: { Label("Rename", systemImage: "pencil") }
            Button { sheet = .editFolder(entry) } label: { Label("Customize…", systemImage: "paintpalette") }
            Button { sheet = .move([entry]) } label: { Label("Move…", systemImage: "folder") }
            Divider()
            Button(role: .destructive) { delete([entry]) } label: { Label("Delete Folder", systemImage: "trash") }
        }
    }

    // MARK: Actions

    private var selectedItems: [LibraryEntry] { items.filter { selection.contains($0.url) } }

    private func toggleSelection(_ item: LibraryEntry) {
        if selection.contains(item.url) { selection.remove(item.url) } else { selection.insert(item.url) }
    }

    private func navigate(to url: URL) {
        NotificationCenter.default.post(name: .navigateToFolder, object: url)
    }

    private func createQuickNote() {
        do {
            let package = try app.createQuickNote(in: folder)
            createdCount += 1
            scene.openNote = .init(package: package)
        } catch {
            scene.show(error)
        }
    }

    private func delete(_ targets: [LibraryEntry], confirmed: Bool = false) {
        // Folders with contents ask first; notes go straight to Recently Deleted, which can restore them.
        if !confirmed, targets.count == 1, let only = targets.first, only.isFolder, (only.itemCount ?? 0) > 0 {
            folderToDelete = only
            return
        }
        do {
            try app.delete(targets.map(\.url))
            deletedCount += 1
            selection.subtract(targets.map(\.url))
            if targets.contains(where: { $0.url == folder }) { NotificationCenter.default.post(name: .folderDeleted, object: folder) }
        } catch {
            scene.show(error)
        }
        folderToDelete = nil
    }

    private func handleDrop(_ urls: [URL], _ location: CGPoint) -> Bool {
        handleDrop(into: folder, urls)
    }

    /// Library items move; anything else is imported.
    private func handleDrop(into destination: URL, _ urls: [URL]) -> Bool {
        let inLibrary = urls.filter { app.isInLibrary($0) && $0 != destination && !destination.path.hasPrefix($0.path + "/") }
        let external = urls.filter { !app.isInLibrary($0) }
        if !inLibrary.isEmpty {
            do { try app.move(inLibrary, to: destination) } catch { scene.show(error) }
        }
        if !external.isEmpty {
            Task { await scene.importFiles(external, into: destination) }
        }
        return !(inLibrary.isEmpty && external.isEmpty)
    }

    private func reload() {
        items = app.library.contents(of: folder, sort: LibrarySort(rawValue: sortRaw) ?? .modified)
        selection = selection.filter { url in items.contains { $0.url == url } }
    }
}

extension Notification.Name {
    /// Posted with a folder URL to push it onto the detail navigation stack.
    static let navigateToFolder = Notification.Name("MBNotes.navigateToFolder")
    static let folderDeleted = Notification.Name("MBNotes.folderDeleted")
}
