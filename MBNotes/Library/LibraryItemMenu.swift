import NoteEngine
import SwiftUI

/// Actions a library screen offers on its items, shared by context menus, swipe actions, and
/// the selection toolbar so every surface behaves the same.
struct LibraryItemActions {
    var rename: (LibraryEntry) -> Void
    var customize: (LibraryEntry) -> Void
    var move: ([LibraryEntry]) -> Void
    var delete: ([LibraryEntry]) -> Void
}

/// The context menu for a note or folder, in Apple's order.
struct LibraryItemMenu: View {
    let item: LibraryEntry
    let actions: LibraryItemActions
    @Environment(AppModel.self) private var app
    @Environment(SceneModel.self) private var scene
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    var body: some View {
        if !item.isFolder {
            Button { app.togglePinned(item) } label: {
                Label(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin")
            }
            if supportsMultipleWindows {
                Button { openWindow(id: "note", value: item.url) } label: { Label("Open in New Window", systemImage: "macwindow.badge.plus") }
            }
            Menu {
                ShareLink(item: NotePDFExport(package: NotePackage(url: item.url), catalog: app.catalog), preview: SharePreview(item.name)) {
                    Label("PDF", systemImage: "doc.richtext")
                }
                ShareLink(item: NoteArchiveExport(package: NotePackage(url: item.url)), preview: SharePreview(item.name)) {
                    Label("MB Notes File", systemImage: "doc.zipper")
                }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        Button { actions.move([item]) } label: { Label("Move…", systemImage: "folder") }
        Button {
            do { _ = try app.library.duplicate(item.url) } catch { scene.show(error) }
            app.refreshLibrary()
        } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        Button { actions.rename(item) } label: { Label("Rename", systemImage: "pencil") }
        if item.isFolder {
            Button { actions.customize(item) } label: { Label("Customize…", systemImage: "paintpalette") }
        }
        Divider()
        Button(role: .destructive) { actions.delete([item]) } label: { Label("Delete", systemImage: "trash") }
    }
}

/// Pick a destination folder from the tree.
struct MoveSheet: View {
    let items: [LibraryEntry]
    @Environment(AppModel.self) private var app
    @Environment(SceneModel.self) private var scene
    @Environment(\.dismiss) private var dismiss
    @State private var tree: [FolderNode] = []
    @State private var newFolderName = ""
    @State private var askingForFolder = false

    private var blocked: Set<URL> {
        var set = Set<URL>()
        for item in items {
            set.insert(item.url.deletingLastPathComponent())
            if item.isFolder { set.insert(item.url) }
        }
        return set
    }

    var body: some View {
        NavigationStack {
            List {
                row(name: "Library", color: nil, url: app.library.root, depth: 0)
                ForEach(FolderNode.flatten(tree), id: \.node.id) { entry in
                    row(name: entry.node.name, color: entry.node.metadata.color, url: entry.node.url, depth: entry.depth + 1)
                }
            }
            .navigationTitle(items.count == 1 ? "Move “\(items[0].name)”" : "Move \(items.count) Items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { newFolderName = ""; askingForFolder = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                }
            }
            .alert("New Folder", isPresented: $askingForFolder) {
                TextField("Name", text: $newFolderName)
                Button("Cancel", role: .cancel) {}
                Button("Create and Move") {
                    do {
                        let url = try app.createFolder(named: newFolderName, in: app.library.root)
                        try app.move(items.map(\.url), to: url)
                        dismiss()
                    } catch { scene.show(error) }
                }
            }
            .task { tree = FolderNode.tree(for: app.library) }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(name: String, color: String?, url: URL, depth: Int) -> some View {
        let disabled = blocked.contains(url) || items.contains { url.path.hasPrefix($0.url.path + "/") }
        return Button {
            do { try app.move(items.map(\.url), to: url) } catch { scene.show(error) }
            dismiss()
        } label: {
            HStack {
                Image(systemName: depth == 0 ? "books.vertical" : "folder.fill")
                    .foregroundStyle(color.map { Color(hex: $0) } ?? .accentColor)
                Text(name)
                Spacer()
                if blocked.contains(url) { Text("Current").font(.footnote).foregroundStyle(.secondary) }
            }
            .padding(.leading, CGFloat(max(0, depth - 1)) * 20)
        }
        .disabled(disabled)
    }
}
