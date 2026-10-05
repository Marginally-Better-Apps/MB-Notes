import NoteEngine
import SwiftUI

/// Small live renderings of pack content for pickers.
struct PaperPreview: View {
    let template: PaperTemplate
    var packID: String
    var accent: String = "#6A45E0"
    var title: String = "Notebook"
    var parameters: [String: Double] = [:]
    @Environment(AppModel.self) private var app

    var body: some View {
        Canvas { context, size in
            context.withCGContext { cg in
                let scale = size.width / 612
                cg.scaleBy(x: scale, y: scale)
                let env = RenderEnvironment(
                    palette: ColorSpec.Palette(accent: ColorSpec.hex(accent) ?? ColorSpec.Palette.standard.accent),
                    variables: ["title": title, "date": Date().formatted(date: .long, time: .omitted), "year": Date().formatted(.dateTime.year())],
                    parameters: parameters,
                    assetURL: { app.catalog.assetURL(packID: packID, path: $0) }
                )
                TemplateRenderer.drawPaper(template, in: cg, rect: CGRect(x: 0, y: 0, width: 612, height: size.height / scale), environment: env)
            }
        }
        .aspectRatio(612 / 792, contentMode: .fit)
        .clipShape(.rect(cornerRadius: Radius.thumb))
        .overlay(RoundedRectangle(cornerRadius: Radius.thumb).strokeBorder(.separator, lineWidth: 0.5))
    }
}

struct CoverPreview: View {
    let design: CoverDesign
    var packID: String
    var accent: String
    var title: String
    var subtitle: String = ""
    @Environment(AppModel.self) private var app

    var body: some View {
        Canvas { context, size in
            context.withCGContext { cg in
                let env = RenderEnvironment(
                    palette: ColorSpec.Palette(accent: ColorSpec.hex(accent) ?? ColorSpec.Palette.standard.accent),
                    variables: ["title": title, "subtitle": subtitle],
                    assetURL: { app.catalog.assetURL(packID: packID, path: $0) }
                )
                TemplateRenderer.drawCover(design, in: cg, rect: CGRect(origin: .zero, size: size), environment: env)
            }
        }
        .aspectRatio(0.75, contentMode: .fit)
        .clipShape(.rect(topLeadingRadius: 3, bottomLeadingRadius: 3, bottomTrailingRadius: Radius.tile, topTrailingRadius: Radius.tile))
        .overlay(UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 3, bottomTrailingRadius: Radius.tile, topTrailingRadius: Radius.tile).strokeBorder(.separator, lineWidth: 0.5))
    }
}

/// A grid of curated colors with names, plus a custom color well.
struct ColorGrid: View {
    @Binding var hex: String
    @Environment(AppModel.self) private var app
    @State private var showMore = false

    private static let names = ["Violet", "Indigo", "Blue", "Teal", "Green", "Amber", "Orange", "Red", "Pink", "Purple", "Brown", "Gray"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 12)], spacing: 12) {
                ForEach(Array(AppTheme.itemColors.enumerated()), id: \.element) { index, color in
                    swatch(color, name: Self.names[safe: index] ?? color)
                }
                ColorPicker("Custom", selection: Binding(get: { Color(hex: hex) }, set: { hex = $0.hexString }), supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 36, height: 36)
            }
            if showMore {
                ForEach(app.catalog.allPalettes.filter { $0.id != "themes" }) { palette in
                    Text(palette.name).font(.footnote).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 12)], spacing: 12) {
                        ForEach(palette.colors, id: \.self) { swatch($0, name: $0) }
                    }
                }
            } else {
                Button("More Colors") { withAnimation { showMore = true } }.font(.footnote)
            }
        }
        .sensoryFeedback(.selection, trigger: hex)
    }

    private func swatch(_ color: String, name: String) -> some View {
        let selected = hex.caseInsensitiveCompare(color) == .orderedSame
        return Button { hex = color } label: {
            Circle()
                .fill(Color(hex: color))
                .frame(width: 36, height: 36)
                .overlay {
                    if selected { Image(systemName: "checkmark").font(.body.weight(.bold)).foregroundStyle(.white) }
                }
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Create a notebook: name, cover, color, first page, and paper.
struct NotebookSheet: View {
    let folder: URL
    @Environment(AppModel.self) private var app
    @Environment(SceneModel.self) private var scene
    @Environment(\.dismiss) private var dismiss
    @FocusState private var titleFocused: Bool
    @State private var title = ""
    @State private var accent = AppTheme.current.accentHex
    @State private var customizedColor = false
    @State private var cover = ContentRef(packID: CorePack.id, itemID: "cloth")
    @State private var paper = ContentRef(packID: CorePack.id, itemID: "lined")
    @State private var titlePage: ContentRef? = ContentRef(packID: CorePack.id, itemID: "title-minimal")
    @State private var sizeName = UserDefaults.standard.string(forKey: "pageSize") ?? "letter"
    @State private var landscape = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(alignment: .top, spacing: 16) {
                        if let design = app.catalog.cover(cover) {
                            CoverPreview(design: design, packID: cover.packID, accent: accent, title: displayTitle)
                                .frame(width: 96)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Name", text: $title)
                                .font(.title3)
                                .focused($titleFocused)
                                .submitLabel(.done)
                                .onSubmit(create)
                            Text(folderName).font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                    }
                    .padding(.vertical, 4)
                }

                Section("Cover") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(app.catalog.allCovers, id: \.ref) { entry in
                                Button {
                                    cover = entry.ref
                                    if !customizedColor, let color = entry.cover.defaultColor { accent = color }
                                } label: {
                                    VStack(spacing: 6) {
                                        CoverPreview(design: entry.cover, packID: entry.ref.packID, accent: accent, title: displayTitle)
                                            .frame(width: 72)
                                            .overlay(selectionRing(entry.ref == cover))
                                        Text(entry.cover.name).font(.caption).foregroundStyle(entry.ref == cover ? .primary : .secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(entry.ref == cover ? .isSelected : [])
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }

                Section("Color") {
                    ColorGrid(hex: Binding(get: { accent }, set: { accent = $0; customizedColor = true }))
                        .padding(.vertical, 4)
                }

                Section("First Page") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            Button { titlePage = nil } label: {
                                VStack(spacing: 6) {
                                    RoundedRectangle(cornerRadius: Radius.thumb)
                                        .fill(.quaternary)
                                        .aspectRatio(612 / 792, contentMode: .fit)
                                        .frame(width: 64)
                                        .overlay(Image(systemName: "nosign").foregroundStyle(.secondary))
                                        .overlay(selectionRing(titlePage == nil))
                                    Text("None").font(.caption)
                                }
                            }
                            .buttonStyle(.plain)
                            ForEach(titlePapers, id: \.ref) { entry in
                                Button { titlePage = entry.ref } label: {
                                    VStack(spacing: 6) {
                                        PaperPreview(template: entry.paper, packID: entry.ref.packID, accent: accent, title: displayTitle)
                                            .frame(width: 64)
                                            .overlay(selectionRing(entry.ref == titlePage))
                                        Text(entry.paper.name).font(.caption).lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(entry.ref == titlePage ? .isSelected : [])
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }

                Section("Paper") {
                    PaperGrid(selection: $paper, accent: accent)
                        .padding(.vertical, 4)
                }

                Section("Page Size") {
                    Picker("Size", selection: $sizeName) {
                        Text("Letter").tag("letter")
                        Text("A4").tag("a4")
                        Text("A5").tag("a5")
                    }
                    .pickerStyle(.segmented)
                    Toggle("Landscape", isOn: $landscape)
                }
            }
            .navigationTitle("New Notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Create", role: .confirm, action: create) }
            }
            .defaultFocus($titleFocused, true)
        }
    }

    private var displayTitle: String { title.isEmpty ? "Notebook" : title }
    private var folderName: String {
        let relative = app.library.relativePath(of: folder) ?? ""
        return relative.isEmpty ? "In All Notes" : "In \(folder.lastPathComponent)"
    }

    private var titlePapers: [(ref: ContentRef, paper: PaperTemplate)] {
        app.catalog.allPapers.filter { $0.paper.role == .title }
    }

    private var pageSize: PageSize {
        let base: PageSize = sizeName == "a4" ? .a4 : sizeName == "a5" ? .a5 : .letter
        return landscape ? base.landscape : base
    }

    private func create() {
        UserDefaults.standard.set(sizeName, forKey: "pageSize")
        let size = NoteFactory.pageSize(for: paper, preferred: pageSize, catalog: app.catalog)
        do {
            let package = try app.createNotebook(title: displayTitle, cover: cover, accent: accent, paper: PaperRef(template: paper), titlePage: titlePage, size: size, in: folder)
            dismiss()
            scene.openNote = .init(package: package)
        } catch {
            scene.show(error)
        }
    }
}

/// Photos-style selection: a tint ring just outside the preview.
func selectionRing(_ selected: Bool) -> some View {
    RoundedRectangle(cornerRadius: Radius.thumb + 3)
        .stroke(.tint, lineWidth: selected ? 2.5 : 0)
        .padding(-3)
}

/// Every writing paper, grouped by category.
struct PaperGrid: View {
    @Binding var selection: ContentRef
    var accent: String
    var parameters: [String: Double] = [:]
    @Environment(AppModel.self) private var app

    var body: some View {
        let papers = app.catalog.allPapers.filter { $0.paper.role == .page }
        let categories = papers.map(\.paper.category).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        VStack(alignment: .leading, spacing: 16) {
            ForEach(categories, id: \.self) { category in
                Text(category).font(.footnote).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72, maximum: 96), spacing: 12)], spacing: 12) {
                    ForEach(papers.filter { $0.paper.category == category }, id: \.ref) { entry in
                        Button { selection = entry.ref } label: {
                            VStack(spacing: 6) {
                                PaperPreview(template: entry.paper, packID: entry.ref.packID, accent: accent, parameters: entry.ref == selection ? parameters : [:])
                                    .overlay(selectionRing(entry.ref == selection))
                                Text(entry.paper.name).font(.caption).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(entry.ref == selection ? .isSelected : [])
                    }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}
