import DesertAnt
import NoteEngine
import SwiftUI

@main
struct MBNotesApp: App {
    @State private var app = AppModel()
    @AppStorage(AppTheme.storageKey) private var themeID = AppTheme.default.rawValue
    @AppStorage(AppearancePreference.storageKey) private var appearanceID = AppearancePreference.system.rawValue

    init() {
        GalaReporter.start(captureOutput: true, screenshotAfter: 3)
        if GalaReporter.endpoint != nil { print("MB Notes collaboration test capture enabled") }
    }

    private var theme: AppTheme { AppTheme(rawValue: themeID) ?? .default }
    private var appearance: AppearancePreference { AppearancePreference(rawValue: appearanceID) ?? .system }

    var body: some Scene {
        WindowGroup {
            SceneRoot(app: app)
                .themed(theme, appearance: appearance)

        }
        .commands { LibraryCommands() }

        // "Open in New Window" on iPad shows a note in its own window.
        WindowGroup(id: "note", for: URL.self) { $url in
            if let url {
                NoteWindow(app: app, url: url)
                    .themed(theme, appearance: appearance)
            }
        }
    }
}

private extension View {
    func themed(_ theme: AppTheme, appearance: AppearancePreference) -> some View {
        environment(\.theme, theme)
            .tint(theme.accent)
            .preferredColorScheme(appearance.colorScheme)
    }
}

/// The library window. Owns the per-window state and presents the editor.
private struct SceneRoot: View {
    let app: AppModel
    @State private var collaborationLink: String?
    @State private var pendingCollaborationLink: String?
    @State private var scene: SceneModel
    @Environment(\.theme) private var theme

    init(app: AppModel) {
        self.app = app
        _scene = State(initialValue: SceneModel(app: app))
    }

    var body: some View {
        RootView()
            .environment(app)
            .environment(scene)
            .onOpenURL { url in
                if url.scheme == "mbnotes", url.host == "collaboration" {
                    if scene.openNote != nil {
                        pendingCollaborationLink = url.absoluteString
                        scene.openNote = nil
                    } else { collaborationLink = url.absoluteString }
                }
                else { scene.handleOpenURL(url) }
            }
            .fullScreenCover(isPresented: Binding(get: { collaborationLink != nil }, set: { if !$0 { collaborationLink = nil } })) {
                CollaborationView(invitation: collaborationLink)
            }
            .fullScreenCover(item: $scene.openNote, onDismiss: {
                if let pending = pendingCollaborationLink {
                    pendingCollaborationLink = nil
                    collaborationLink = pending
                }
            }) { note in
                EditorView(package: note.package, initialPageID: note.pageID) { scene.openNote = nil }
                    .environment(app)
                    .environment(scene)
                    .environment(\.theme, theme)
                    .tint(theme.accent)
            }
            .alert(item: $scene.alert) { alert in
                Alert(title: Text(alert.title), message: Text(alert.message))
            }
            .sheet(item: $scene.pendingPack) { preview in
                PackPreviewSheet(preview: preview)
                    .environment(app)
                    .environment(scene)
            }
            .overlay {
                if let progress = scene.importProgress {
                    VStack(spacing: 10) {
                        ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total)))
                            .frame(width: 180)
                        Text(progress.total > 1 ? "Importing \(min(progress.completed + 1, progress.total)) of \(progress.total)…" : "Importing…")
                            .font(.subheadline)
                    }
                    .padding(24)
                    .glassEffect(.regular, in: .rect(cornerRadius: Radius.panel))
                }
            }
    }
}

/// A note in its own iPad window.
private struct NoteWindow: View {
    let app: AppModel
    let url: URL
    @State private var scene: SceneModel
    @Environment(\.dismissWindow) private var dismissWindow

    init(app: AppModel, url: URL) {
        self.app = app
        self.url = url
        _scene = State(initialValue: SceneModel(app: app))
    }

    var body: some View {
        EditorView(package: NotePackage(url: url), initialPageID: nil) { dismissWindow() }
            .environment(app)
            .environment(scene)
            .alert(item: $scene.alert) { alert in
                Alert(title: Text(alert.title), message: Text(alert.message))
            }
    }
}

/// Menu-bar and keyboard commands. Views pick them up through the focused-value keys below.
struct LibraryCommands: Commands {
    @FocusedValue(\.libraryActions) private var library
    @FocusedValue(\.editorActions) private var editor

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") { library?.newNote() }
                .keyboardShortcut("n")
            Button("New Notebook…") { library?.newNotebook() }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Button("New Folder") { library?.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Import…") { library?.importFiles() }
                .keyboardShortcut("o")
            Button("Scan Documents…") { library?.scan() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        }
        CommandMenu("View") {
            Button("As Gallery") { library?.setLayout(.gallery) }
                .keyboardShortcut("1")
                .disabled(library == nil)
            Button("As List") { library?.setLayout(.list) }
                .keyboardShortcut("2")
                .disabled(library == nil)
        }
        CommandMenu("Note") {
            ForEach(Array(EditorMode.allCases.enumerated()), id: \.element) { index, mode in
                Button(mode.title) { editor?.setMode(mode) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
                    .disabled(editor == nil)
            }
            Divider()
            Button("Delete Selected") { editor?.deleteSelection() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(editor == nil)
        }
    }
}

/// What the focused library view can do, for keyboard commands.
struct LibraryActions {
    var newNote: () -> Void
    var newNotebook: () -> Void
    var newFolder: () -> Void
    var importFiles: () -> Void
    var scan: () -> Void
    var setLayout: (LibraryLayout) -> Void
}

extension FocusedValues {
    @Entry var libraryActions: LibraryActions?
}

enum LibraryLayout: String, CaseIterable {
    case gallery, list
}
