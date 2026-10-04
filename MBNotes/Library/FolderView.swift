import NoteEngine
import SwiftUI
import UniformTypeIdentifiers

struct FolderView: View {
    let folder: URL
    @Environment(AppModel.self) private var app
    @AppStorage("librarySort") private var sortRaw = LibrarySort.modified.rawValue
    @State private var items: [LibraryEntry] = []
    @State private var query = ""
    @State private var searchResults: [SearchResult] = []
    @State private var sheet: Sheet?
    @State private var renaming: LibraryEntry?
    @State private var newName = ""
    @State private var showImporter = false

    enum Sheet: Identifiable {
        case newNotebook, newNote, newFolder
        case editFolder(LibraryEntry)
        case move(LibraryEntry)

        var id: String {
            switch self {
            case .newNotebook: return "notebook"
            case .newNote: return "note"
            case .newFolder: return "folder"
            case .editFolder(let item): return "edit-\(item.url.path)"
            case .move(let item): return "move-\(item.url.path)"
            }
        }
    }

    private var isRoot: Bool { folder.standardizedFileURL == app.library.root.standardizedFileURL }
    private var title: String { isRoot ? "Library" : folder.lastPathComponent }

    var body: some View {
        ScrollView {
            if !query.isEmpty {
                SearchResultsList(results: searchResults)
                    .padding()
            } else if items.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 24, alignment: .top)], spacing: 28) {
                    ForEach(items) { item in
                        tile(for: item)
                    }
                }
                .padding(24)
            }
        }
        .background(BrandBackdrop(intensity: 0.45))
        .navigationTitle(title)
        .searchable(text: $query, prompt: "Search titles, handwriting, and transcripts")
        .task(id: query) {
            guard !query.isEmpty else { searchResults = []; return }
            try? await Task.sleep(for: .milliseconds(250))
            searchResults = await SearchIndex.search(query, in: app.library)
        }
        .toolbar { toolbar }
        .task(id: app.libraryVersion) { reload() }
        .onChange(of: sortRaw) { reload() }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .newNotebook: NewNoteSheet(mode: .notebook, folder: folder)
            case .newNote: NewNoteSheet(mode: .note, folder: folder)
            case .newFolder: FolderEditorSheet(parent: folder, editing: nil)
            case .editFolder(let item): FolderEditorSheet(parent: folder, editing: item)
            case .move(let item): MoveSheet(item: item)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: DocumentImporter.supportedTypes + packTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { await app.importFiles(urls, into: folder) }
            }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let item = renaming {
                    do { try app.library.rename(item.url, to: newName) } catch { app.show(error) }
                    app.refreshLibrary()
                }
                renaming = nil
            }
        }
    }

    private var packTypes: [UTType] {
        [UTType(exportedAs: "com.marginallybetter.notes.pack"), UTType(exportedAs: "com.marginallybetter.notes.note")]
    }

    @ViewBuilder private func tile(for item: LibraryEntry) -> some View {
        Group {
            if item.isFolder {
                NavigationLink(value: item.url) { FolderTile(item: item) }
                    .dropDestination(for: URL.self) { urls, _ in
                        for url in urls where url != item.url { _ = try? app.library.move(url, to: item.url) }
                        app.refreshLibrary()
                        return true
                    }
            } else {
                Button { app.openNote = .init(package: NotePackage(url: item.url)) } label: { NoteTile(item: item) }
            }
        }
        .buttonStyle(.plain)
        .draggable(item.url)
        .contextMenu { menu(for: item) }
    }

    @ViewBuilder private func menu(for item: LibraryEntry) -> some View {
        Button { newName = item.name; renaming = item } label: { Label("Rename", systemImage: "pencil") }
        if item.isFolder {
            Button { sheet = .editFolder(item) } label: { Label("Customize", systemImage: "paintpalette") }
        }
        Button { sheet = .move(item) } label: { Label("Move", systemImage: "folder") }
        Button {
            _ = try? app.library.duplicate(item.url)
            app.refreshLibrary()
        } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        if !item.isFolder {
            ShareLink(item: item.url) { Label("Share note file", systemImage: "square.and.arrow.up") }
        }
        Divider()
        Button(role: .destructive) {
            do { try app.library.delete(item.url) } catch { app.show(error) }
            app.refreshLibrary()
        } label: { Label("Delete", systemImage: "trash") }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { sheet = .newNotebook } label: { Label("Notebook", systemImage: "book.closed.fill") }
                Button { sheet = .newNote } label: { Label("Quick note", systemImage: "note.text") }
                Button { sheet = .newFolder } label: { Label("Folder", systemImage: "folder.fill.badge.plus") }
                Divider()
                Button { showImporter = true } label: { Label("Import PDF, slides, or documents", systemImage: "square.and.arrow.down") }
            } label: {
                Label("New", systemImage: "plus")
            }
            .buttonStyle(.glassProminent)
        }
        ToolbarItem(placement: .secondaryAction) {
            Picker("Sort", selection: $sortRaw) {
                Text("Last edited").tag(LibrarySort.modified.rawValue)
                Text("Name").tag(LibrarySort.name.rawValue)
                Text("Date created").tag(LibrarySort.created.rawValue)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 44))
                .foregroundStyle(Brand.gradient)
            Text("Nothing here yet")
                .font(.title3.weight(.semibold))
            Text("Make a notebook, start a quick note, or import a PDF or slide deck to write on.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
            HStack {
                Button("New notebook") { sheet = .newNotebook }
                    .buttonStyle(.glassProminent)
                Button("Import") { showImporter = true }
                    .buttonStyle(.glass)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func reload() {
        items = app.library.contents(of: folder, sort: LibrarySort(rawValue: sortRaw) ?? .modified)
    }
}

struct RecentsView: View {
    @Environment(AppModel.self) private var app
    @State private var items: [LibraryEntry] = []

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 24, alignment: .top)], spacing: 28) {
                ForEach(items) { item in
                    Button { app.openNote = .init(package: NotePackage(url: item.url)) } label: { NoteTile(item: item) }
                        .buttonStyle(.plain)
                }
            }
            .padding(24)
        }
        .background(BrandBackdrop(intensity: 0.45))
        .navigationTitle("Recents")
        .task(id: app.libraryVersion) { items = Array(app.library.allNotes().prefix(40)) }
    }
}

struct TrashView: View {
    @Environment(AppModel.self) private var app
    @State private var items: [LibraryEntry] = []

    var body: some View {
        List {
            if items.isEmpty {
                ContentUnavailableView("Nothing deleted", systemImage: "trash", description: Text("Deleted notes and folders wait here until you empty the trash."))
            }
            ForEach(items) { item in
                HStack {
                    Image(systemName: item.isFolder ? "folder.fill" : "doc.richtext.fill")
                        .foregroundStyle(Brand.pink)
                    Text(item.name)
                    Spacer()
                    Button("Restore") {
                        _ = try? app.library.restore(item.url)
                        app.refreshLibrary()
                    }
                    .buttonStyle(.glass)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(BrandBackdrop(intensity: 0.45))
        .navigationTitle("Recently Deleted")
        .toolbar {
            Button("Empty", role: .destructive) {
                try? app.library.emptyTrash()
                app.refreshLibrary()
            }
            .disabled(items.isEmpty)
        }
        .task(id: app.libraryVersion) { items = app.library.trashedItems() }
    }
}

struct MoveSheet: View {
    let item: LibraryEntry
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(app.library.allFolders().filter { !$0.path.hasPrefix(item.url.path) }, id: \.self) { folder in
                Button {
                    do { try app.library.move(item.url, to: folder) } catch { app.show(error) }
                    app.refreshLibrary()
                    dismiss()
                } label: {
                    Label(name(for: folder), systemImage: "folder.fill")
                }
            }
            .navigationTitle("Move “\(item.name)”")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Cancel") { dismiss() } }
        }
    }

    private func name(for folder: URL) -> String {
        let root = app.library.root.standardizedFileURL.path
        let path = folder.standardizedFileURL.path
        return path == root ? "Library" : String(path.dropFirst(root.count + 1))
    }
}
