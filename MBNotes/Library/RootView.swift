import NoteEngine
import SwiftUI

enum SidebarItem: Hashable {
    case library, recents, trash
    case folder(URL)

    /// A string form for scene restoration.
    var restorationValue: String {
        switch self {
        case .library: return "library"
        case .recents: return "recents"
        case .trash: return "trash"
        case .folder(let url): return "folder:" + url.path
        }
    }

    init?(restorationValue: String) {
        switch restorationValue {
        case "library": self = .library
        case "recents": self = .recents
        case "trash": self = .trash
        default:
            guard restorationValue.hasPrefix("folder:") else { return nil }
            self = .folder(URL(fileURLWithPath: String(restorationValue.dropFirst(7)), isDirectory: true))
        }
    }
}

/// Sidebar with the library's collections and folder tree; the selected folder on the right.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(SceneModel.self) private var scene
    @Environment(\.horizontalSizeClass) private var sizeClass
    @SceneStorage("sidebarSelection") private var storedSelection = "library"
    @SceneStorage("folderPath") private var storedPath = ""
    @State private var selection: SidebarItem? = .library
    @State private var path: [URL] = []
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    @State private var preferredColumn = NavigationSplitViewColumn.detail
    @State private var tree: [FolderNode] = []
    @State private var showSettings = false
    @State private var newFolderParent: URL?
    @State private var newFolderName = ""
    @State private var dropTarget: URL?
    @Namespace private var zoom

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredColumn) {
            sidebar
        } detail: {
            NavigationStack(path: $path) {
                detail
                    .navigationDestination(for: URL.self) { url in
                        FolderView(folder: url)
                    }
            }
        }
        .environment(\.zoomNamespace, zoom)
        .task(id: app.libraryVersion) { tree = FolderNode.tree(for: app.library) }
        .onAppear(perform: restore)
        .onChange(of: selection) { _, new in
            path = []
            storedSelection = new?.restorationValue ?? "library"
            // A dead folder (deleted in Files) falls back to the library.
            if case .folder(let url) = new, !FileManager.default.fileExists(atPath: url.path) { selection = .library }
        }
        .onChange(of: path) { _, new in
            storedPath = new.map(\.path).joined(separator: "\n")
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToFolder)) { note in
            if let url = note.object as? URL { path.append(url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .folderDeleted)) { note in
            guard let url = note.object as? URL else { return }
            if case .folder(let selected) = selection, selected == url { selection = .library }
            path.removeAll { $0 == url || $0.path.hasPrefix(url.path + "/") }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .navigationDestination(isPresented: .constant(UserDefaults.standard.bool(forKey: "showTheme"))) { ThemePicker() }
            }
                .environment(app)
                .environment(scene)
        }
        .alert("New Folder", isPresented: Binding(get: { newFolderParent != nil }, set: { if !$0 { newFolderParent = nil } })) {
            TextField("Name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderParent = nil }
            Button("Create") {
                if let parent = newFolderParent {
                    do { selection = .folder(try app.createFolder(named: newFolderName, in: parent)) } catch { scene.show(error) }
                }
                newFolderParent = nil
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                Label("All Notes", systemImage: "note.text").tag(SidebarItem.library)
                Label("Recents", systemImage: "clock").tag(SidebarItem.recents)
                Label("Recently Deleted", systemImage: "trash").tag(SidebarItem.trash)
            }
            Section("Folders") {
                OutlineGroup(tree, children: \.children) { node in
                    folderRow(node)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("MB Notes")
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button {
                    newFolderName = ""
                    newFolderParent = app.library.root
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
            }
        }
    }

    private func folderRow(_ node: FolderNode) -> some View {
        Label {
            Text(node.name)
        } icon: {
            Image(systemName: "folder.fill").foregroundStyle(Color(hex: node.metadata.color))
        }
        .badge(node.noteCount)
        .tag(SidebarItem.folder(node.url))
        .listRowBackground(dropTarget == node.url ? Color.accentColor.opacity(0.15) : nil)
        .dropDestination(for: URL.self) { urls, _ in
            do { try app.move(urls.filter { $0 != node.url }, to: node.url) } catch { scene.show(error) }
            return true
        } isTargeted: { dropTarget = $0 ? node.url : nil }
        .contextMenu {
            Button { newFolderName = ""; newFolderParent = node.url } label: { Label("New Subfolder", systemImage: "folder.badge.plus") }
            Divider()
            Button(role: .destructive) {
                do { try app.delete([node.url]) } catch { scene.show(error) }
                if selection == .folder(node.url) { selection = .library }
            } label: { Label("Delete", systemImage: "trash") }
        }
    }

    @ViewBuilder private var detail: some View {
        switch selection ?? .library {
        case .library: FolderView(folder: app.library.root)
        case .recents: RecentsView()
        case .trash: TrashView()
        case .folder(let url): FolderView(folder: url)
        }
    }

    private func restore() {
        #if DEBUG
        // Screenshot hook: `-showSettings 1` opens Settings on launch; `-showTheme 1` the theme picker.
        if UserDefaults.standard.bool(forKey: "showSettings") || UserDefaults.standard.bool(forKey: "showTheme") { showSettings = true }
        #endif
        if let item = SidebarItem(restorationValue: storedSelection) { selection = item }
        let urls = storedPath.split(separator: "\n").map { URL(fileURLWithPath: String($0), isDirectory: true) }
        if urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) { path = urls }
    }
}
