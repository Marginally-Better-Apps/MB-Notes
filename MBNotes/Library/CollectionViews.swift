import NoteEngine
import SwiftUI

/// Notes across every folder, newest first.
struct RecentsView: View {
    @Environment(AppModel.self) private var app
    @Environment(SceneModel.self) private var scene
    @Environment(\.zoomNamespace) private var zoom
    @State private var items: [LibraryEntry] = []
    @State private var moving: [LibraryEntry]?

    var body: some View {
        List {
            if items.isEmpty {
                ContentUnavailableView("No Recent Notes", systemImage: "clock", description: Text("Notes you open or edit show up here."))
            }
            ForEach(LibraryDateGroup.group(items)) { group in
                Section(group.title) {
                    ForEach(group.items) { item in
                        Button { scene.open(item.url) } label: { NoteRow(item: item) }
                            .buttonStyle(.plain)
                            .modifier(MatchedSource(id: item.url, namespace: zoom))
                            .contextMenu { LibraryItemMenu(item: item, actions: actions) }
                            .swipeActions(edge: .leading) {
                                Button { app.togglePinned(item) } label: { Label(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin") }
                                    .tint(.orange)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { actions.delete([item]) } label: { Label("Delete", systemImage: "trash") }
                                Button { moving = [item] } label: { Label("Move", systemImage: "folder") }
                            }
                    }
                }
            }
        }
        .navigationTitle("Recents")
        .task(id: app.libraryVersion) { items = Array(app.library.allNotes().prefix(60)) }
        .sheet(item: Binding(get: { moving.map(MoveItems.init) }, set: { moving = $0?.items })) { MoveSheet(items: $0.items) }
    }

    private var actions: LibraryItemActions {
        LibraryItemActions(
            rename: { _ in },
            customize: { _ in },
            move: { moving = $0 },
            delete: { items in
                do { try app.delete(items.map(\.url)) } catch { scene.show(error) }
            }
        )
    }
}

struct MoveItems: Identifiable {
    let items: [LibraryEntry]
    var id: String { items.map(\.url.path).joined() }
}

/// Deleted items wait here for 30 days and go back where they came from when restored.
struct TrashView: View {
    @Environment(AppModel.self) private var app
    @Environment(SceneModel.self) private var scene
    @State private var items: [LibraryEntry] = []
    @State private var confirmEmpty = false
    @State private var pendingPermanent: LibraryEntry?

    var body: some View {
        List {
            if items.isEmpty {
                ContentUnavailableView("No Deleted Items", systemImage: "trash", description: Text("Deleted notes and folders stay here for 30 days."))
            }
            ForEach(items) { item in
                HStack(spacing: 12) {
                    if item.isFolder {
                        Image(systemName: "folder.fill").font(.title2).foregroundStyle(Color(hex: item.folder?.color ?? "#6A45E0")).frame(width: 44)
                    } else {
                        NoteThumbnail(item: item).frame(width: 44)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name).lineLimit(1)
                        Text(remaining(for: item)).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .swipeActions(edge: .leading) {
                    Button { restore(item) } label: { Label("Recover", systemImage: "arrow.uturn.backward") }
                        .tint(.accentColor)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { pendingPermanent = item } label: { Label("Delete Now", systemImage: "trash") }
                }
                .contextMenu {
                    Button { restore(item) } label: { Label("Recover", systemImage: "arrow.uturn.backward") }
                    Button(role: .destructive) { pendingPermanent = item } label: { Label("Delete Now", systemImage: "trash") }
                }
            }
        }
        .navigationTitle("Recently Deleted")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Recover All") { items.forEach(restore) }
                    Button("Empty Recently Deleted", role: .destructive) { confirmEmpty = true }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .disabled(items.isEmpty)
            }
        }
        .confirmationDialog("Permanently delete \(items.count) \(items.count == 1 ? "item" : "items")?", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) {
                do { try app.library.emptyTrash() } catch { scene.show(error) }
                app.refreshLibrary()
            }
        } message: {
            Text("This can't be undone.")
        }
        .confirmationDialog("Permanently delete “\(pendingPermanent?.name ?? "")”?", isPresented: Binding(get: { pendingPermanent != nil }, set: { if !$0 { pendingPermanent = nil } }), titleVisibility: .visible) {
            Button("Delete Now", role: .destructive) {
                if let item = pendingPermanent {
                    do { try app.library.deletePermanently(item.url) } catch { scene.show(error) }
                    app.refreshLibrary()
                }
            }
        }
        .task(id: app.libraryVersion) { items = app.library.trashedItems() }
    }

    private func restore(_ item: LibraryEntry) {
        do { _ = try app.library.restore(item.url) } catch { scene.show(error) }
        app.refreshLibrary()
    }

    private func remaining(for item: LibraryEntry) -> String {
        let deleted = app.library.deletionInfo(for: item.url)?.deletedAt ?? item.modifiedAt
        let days = max(0, 30 - Int(Date().timeIntervalSince(deleted) / 86_400))
        return days == 1 ? "1 day left" : "\(days) days left"
    }
}

/// Notes-style date sections: Today, Yesterday, Previous 7 Days, Previous 30 Days, then months.
struct LibraryDateGroup: Identifiable {
    let title: String
    let items: [LibraryEntry]
    var id: String { title }

    static func group(_ items: [LibraryEntry]) -> [LibraryDateGroup] {
        let calendar = Calendar.current
        let now = Date()
        var buckets: [(String, [LibraryEntry])] = []
        func append(_ title: String, _ item: LibraryEntry) {
            if let index = buckets.firstIndex(where: { $0.0 == title }) { buckets[index].1.append(item) } else { buckets.append((title, [item])) }
        }
        for item in items {
            let date = item.modifiedAt
            if calendar.isDateInToday(date) { append("Today", item) }
            else if calendar.isDateInYesterday(date) { append("Yesterday", item) }
            else if let week = calendar.date(byAdding: .day, value: -7, to: now), date > week { append("Previous 7 Days", item) }
            else if let month = calendar.date(byAdding: .day, value: -30, to: now), date > month { append("Previous 30 Days", item) }
            else if calendar.isDate(date, equalTo: now, toGranularity: .year) { append(date.formatted(.dateTime.month(.wide)), item) }
            else { append(date.formatted(.dateTime.year()), item) }
        }
        return buckets.map { LibraryDateGroup(title: $0.0, items: $0.1) }
    }
}
