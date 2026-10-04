import NoteEngine
import SwiftUI

enum SidebarItem: Hashable {
    case library, recents, trash, packs, settings
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var selection: SidebarItem? = .library
    @State private var path: [URL] = []

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label("Library", systemImage: "books.vertical.fill").tag(SidebarItem.library)
                    Label("Recents", systemImage: "clock.fill").tag(SidebarItem.recents)
                    Label("Recently Deleted", systemImage: "trash.fill").tag(SidebarItem.trash)
                }
                Section("Make it yours") {
                    Label("Packs", systemImage: "shippingbox.fill").tag(SidebarItem.packs)
                    Label("Settings", systemImage: "gearshape.fill").tag(SidebarItem.settings)
                }
            }
            .navigationTitle("MB Notes")
            .scrollContentBackground(.hidden)
            .background(BrandBackdrop(intensity: 0.6))
        } detail: {
            NavigationStack(path: $path) {
                detail
                    .navigationDestination(for: URL.self) { url in
                        FolderView(folder: url)
                    }
            }
        }
        .onChange(of: selection) { path = [] }
    }

    @ViewBuilder private var detail: some View {
        switch selection ?? .library {
        case .library: FolderView(folder: app.library.root)
        case .recents: RecentsView()
        case .trash: TrashView()
        case .packs: PacksView()
        case .settings: SettingsView()
        }
    }
}
