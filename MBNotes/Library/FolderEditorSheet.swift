import NoteEngine
import SwiftUI

/// Create or customize a folder: name, color, and symbol.
struct FolderEditorSheet: View {
    let parent: URL
    let editing: LibraryEntry?
    @Environment(AppModel.self) private var app
    @Environment(SceneModel.self) private var scene
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool
    @State private var name = ""
    @State private var metadata = FolderMetadata(color: AppTheme.current.accentHex, symbol: "folder.fill")
    @State private var symbolQuery = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 14) {
                        FolderGlyph(metadata: metadata)
                            .frame(width: 120)
                        TextField("Name", text: $name)
                            .multilineTextAlignment(.center)
                            .font(.title3)
                            .focused($nameFocused)
                            .submitLabel(.done)
                            .onSubmit(save)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                Section("Color") {
                    ColorGrid(hex: $metadata.color).padding(.vertical, 4)
                }

                Section {
                    TextField("Search Symbols", text: $symbolQuery)
                        .textFieldStyle(.roundedBorder)
                    ForEach(app.catalog.allSymbolSets) { set in
                        let symbols = set.symbols.filter { symbolQuery.isEmpty || $0.localizedCaseInsensitiveContains(symbolQuery) }
                        if !symbols.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(set.name).font(.footnote).foregroundStyle(.secondary)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 8)], spacing: 8) {
                                    ForEach(symbols, id: \.self) { symbol in
                                        let selected = metadata.symbol == symbol
                                        Button { metadata.symbol = symbol } label: {
                                            Image(systemName: symbol)
                                                .font(.title3)
                                                .frame(width: 44, height: 44)
                                                .foregroundStyle(selected ? Color(hex: metadata.color) : .primary)
                                                .background(selected ? Color(hex: metadata.color).opacity(0.15) : Color.clear, in: .rect(cornerRadius: Radius.tile))
                                        }
                                        .buttonStyle(.plain)
                                        .hoverEffect(.highlight)
                                        .accessibilityLabel(symbol.replacingOccurrences(of: ".", with: " "))
                                        .accessibilityAddTraits(selected ? .isSelected : [])
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    Text("Symbol")
                }
            }
            .navigationTitle(editing == nil ? "New Folder" : "Customize Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(editing == nil ? "Create" : "Done", role: .confirm, action: save) }
            }
            .onAppear(perform: load)
            .defaultFocus($nameFocused, editing == nil)
            .sensoryFeedback(.selection, trigger: metadata.symbol)
        }
    }

    private func load() {
        if let editing, let folder = editing.folder {
            name = editing.name
            metadata = folder
        } else {
            metadata.color = app.nextAccent()
        }
    }

    private func save() {
        do {
            if let editing {
                var url = editing.url
                if name != editing.name, !name.isEmpty { url = try app.library.rename(url, to: name) }
                try app.library.writeFolderMetadata(metadata, at: url)
            } else {
                let url = try app.createFolder(named: name.isEmpty ? "New Folder" : name, in: parent, color: metadata.color, symbol: metadata.symbol)
                try app.library.writeFolderMetadata(metadata, at: url)
            }
            app.refreshLibrary()
            dismiss()
        } catch {
            scene.show(error)
        }
    }
}
