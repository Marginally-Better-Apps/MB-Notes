import NoteEngine
import SwiftUI

/// Create or customize a folder: name, color, symbol, and stickers you can drag around.
struct FolderEditorSheet: View {
    let parent: URL
    let editing: LibraryEntry?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var metadata = FolderMetadata(color: "#8056F6", symbol: "folder.fill")
    @State private var selectedSticker: UUID?
    @State private var showStickers = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    preview
                        .frame(maxWidth: 300)
                        .frame(maxWidth: .infinity)

                    if let index = metadata.stickers.firstIndex(where: { $0.id == selectedSticker }) {
                        stickerControls(index)
                    }

                    TextField("Folder name", text: $name)
                        .font(.title3.weight(.semibold))
                        .padding(14)
                        .glassEffect(.regular, in: .rect(cornerRadius: 16))

                    VStack(alignment: .leading) {
                        Text("Color").font(.headline)
                        ColorRow(hex: $metadata.color)
                    }

                    Button {
                        showStickers = true
                    } label: {
                        Label("Add a sticker", systemImage: "face.smiling")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)

                    ForEach(app.catalog.allSymbolSets) { set in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(set.name).font(.headline)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 46), spacing: 10)], spacing: 10) {
                                ForEach(set.symbols, id: \.self) { symbol in
                                    Image(systemName: symbol)
                                        .font(.title3)
                                        .frame(width: 46, height: 46)
                                        .foregroundStyle(metadata.symbol == symbol ? .white : Color(hex: metadata.color))
                                        .background(metadata.symbol == symbol ? Color(hex: metadata.color) : Color.clear, in: .rect(cornerRadius: 12))
                                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
                                        .onTapGesture { metadata.symbol = symbol }
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(BrandBackdrop(intensity: 0.35))
            .navigationTitle(editing == nil ? "New folder" : "Customize folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Create" : "Save") { save() }
                        .buttonStyle(.glassProminent)
                }
            }
            .sheet(isPresented: $showStickers) {
                StickerPicker { ref in
                    let placed = PlacedSticker(sticker: ref, x: 0.75, y: 0.35, scale: 1, rotation: Double.random(in: -0.3...0.3))
                    metadata.stickers.append(placed)
                    selectedSticker = placed.id
                }
            }
            .onAppear(perform: load)
        }
    }

    private var preview: some View {
        GeometryReader { geo in
            ZStack {
                FolderArt(metadata: FolderMetadata(color: metadata.color, symbol: metadata.symbol), catalog: app.catalog)
                ForEach($metadata.stickers) { $placed in
                    StickerView(ref: placed.sticker, catalog: app.catalog)
                        .frame(width: geo.size.width * 0.3 * placed.scale, height: geo.size.width * 0.3 * placed.scale)
                        .rotationEffect(.radians(placed.rotation))
                        .overlay {
                            if selectedSticker == placed.id {
                                Circle().stroke(Brand.pink, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                            }
                        }
                        .position(x: placed.x * geo.size.width, y: placed.y * geo.size.height)
                        .gesture(DragGesture().onChanged { value in
                            selectedSticker = placed.id
                            placed.x = min(1, max(0, value.location.x / geo.size.width))
                            placed.y = min(1, max(0, value.location.y / geo.size.height))
                        })
                        .onTapGesture { selectedSticker = placed.id }
                }
            }
        }
        .aspectRatio(1.15, contentMode: .fit)
    }

    private func stickerControls(_ index: Int) -> some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                Slider(value: $metadata.stickers[index].scale, in: 0.4...2)
            }
            HStack {
                Image(systemName: "rotate.right")
                Slider(value: $metadata.stickers[index].rotation, in: -Double.pi...Double.pi)
            }
            Button(role: .destructive) {
                metadata.stickers.remove(at: index)
                selectedSticker = nil
            } label: {
                Label("Remove sticker", systemImage: "trash")
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
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
        if let editing {
            do {
                var url = editing.url
                if name != editing.name, !name.isEmpty { url = try app.library.rename(url, to: name) }
                try app.library.writeFolderMetadata(metadata, at: url)
            } catch {
                app.show(error)
            }
            app.refreshLibrary()
        } else if let url = app.createFolder(named: name.isEmpty ? "New Folder" : name, in: parent, color: metadata.color, symbol: metadata.symbol) {
            try? app.library.writeFolderMetadata(metadata, at: url)
            app.refreshLibrary()
        }
        dismiss()
    }
}

/// Browse every sticker from every installed pack.
struct StickerPicker: View {
    var onPick: (ContentRef) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                let stickers = app.catalog.allStickers
                let categories = stickers.map(\.sticker.category).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(categories, id: \.self) { category in
                        Text(category).font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 12)], spacing: 12) {
                            ForEach(stickers.filter { $0.sticker.category == category }, id: \.ref) { entry in
                                Button {
                                    onPick(entry.ref)
                                    dismiss()
                                } label: {
                                    StickerView(ref: entry.ref, catalog: app.catalog)
                                        .frame(width: 58, height: 58)
                                        .padding(4)
                                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text(entry.sticker.name))
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(BrandBackdrop(intensity: 0.3))
            .navigationTitle("Stickers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
        .presentationDetents([.medium, .large])
    }
}
