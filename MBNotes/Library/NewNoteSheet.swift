import NoteEngine
import SwiftUI

/// Small live renderings of pack content for pickers.
struct PaperPreview: View {
    let template: PaperTemplate
    var packID: String
    var accent: String = "#F76CA0"
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
        .clipShape(.rect(cornerRadius: 6))
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }
}

struct CoverPreview: View {
    let design: CoverDesign
    var packID: String
    var accent: String
    var title: String
    var subtitle: String = ""
    var stickers: [PlacedSticker] = []
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
        .overlay {
            GeometryReader { geo in
                ForEach(stickers) { placed in
                    StickerView(ref: placed.sticker, catalog: app.catalog)
                        .frame(width: geo.size.width * 0.28 * placed.scale, height: geo.size.width * 0.28 * placed.scale)
                        .rotationEffect(.radians(placed.rotation))
                        .position(x: placed.x * geo.size.width, y: placed.y * geo.size.height)
                }
            }
        }
        .aspectRatio(0.75, contentMode: .fit)
        .clipShape(.rect(topLeadingRadius: 4, bottomLeadingRadius: 4, bottomTrailingRadius: 12, topTrailingRadius: 12))
        .shadow(color: .black.opacity(0.18), radius: 5, y: 3)
    }
}

/// A swatch row: palette colors plus a custom color well.
struct ColorRow: View {
    @Binding var hex: String
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(colors, id: \.self) { color in
                    Circle()
                        .fill(Color(hex: color))
                        .frame(width: 32, height: 32)
                        .overlay(Circle().stroke(.white, lineWidth: hex == color ? 3 : 0))
                        .overlay(Circle().stroke(Color(hex: color), lineWidth: hex == color ? 2 : 0).padding(-3))
                        .onTapGesture { hex = color }
                        .accessibilityLabel(Text(color))
                }
                ColorPicker("Custom", selection: Binding(get: { Color(hex: hex) }, set: { hex = $0.hexString }), supportsOpacity: false)
                    .labelsHidden()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 2)
        }
    }

    private var colors: [String] {
        var seen = Set<String>()
        return app.catalog.allPalettes.flatMap(\.colors).filter { seen.insert($0.uppercased()).inserted }
    }
}

struct NewNoteSheet: View {
    enum Mode { case notebook, note }

    let mode: Mode
    let folder: URL
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var accent = "#F76CA0"
    @State private var cover = ContentRef(packID: CorePack.id, itemID: "classic")
    @State private var paper = ContentRef(packID: CorePack.id, itemID: "lined")
    @State private var titlePage: ContentRef? = ContentRef(packID: CorePack.id, itemID: "title-classic")
    @State private var sizeName = UserDefaults.standard.string(forKey: "pageSize") ?? "letter"
    @State private var landscape = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    TextField(mode == .notebook ? "Notebook name" : "Note name", text: $title)
                        .font(.title2.weight(.semibold))
                        .padding(14)
                        .glassEffect(.regular, in: .rect(cornerRadius: 16))

                    section("Color") { ColorRow(hex: $accent) }

                    if mode == .notebook {
                        section("Cover") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 14) {
                                    ForEach(app.catalog.allCovers, id: \.ref) { entry in
                                        CoverPreview(design: entry.cover, packID: entry.ref.packID, accent: accent, title: displayTitle)
                                            .frame(width: 110)
                                            .overlay(selectionRing(entry.ref == cover))
                                            .onTapGesture {
                                                cover = entry.ref
                                                if let color = entry.cover.defaultColor { accent = color }
                                            }
                                    }
                                }
                                .padding(6)
                            }
                        }
                        section("First page") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 14) {
                                    VStack {
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(.background)
                                            .aspectRatio(612 / 792, contentMode: .fit)
                                            .overlay(Image(systemName: "nosign").foregroundStyle(.secondary))
                                            .overlay(selectionRing(titlePage == nil))
                                        Text("None").font(.caption)
                                    }
                                    .frame(width: 96)
                                    .onTapGesture { titlePage = nil }
                                    ForEach(titlePapers, id: \.ref) { entry in
                                        VStack {
                                            PaperPreview(template: entry.paper, packID: entry.ref.packID, accent: accent, title: displayTitle)
                                                .overlay(selectionRing(entry.ref == titlePage))
                                            Text(entry.paper.name).font(.caption).lineLimit(1)
                                        }
                                        .frame(width: 96)
                                        .onTapGesture { titlePage = entry.ref }
                                    }
                                }
                                .padding(6)
                            }
                        }
                    }

                    section("Paper") {
                        PaperGrid(selection: $paper, accent: accent)
                    }

                    section("Page size") {
                        HStack {
                            Picker("Size", selection: $sizeName) {
                                Text("Letter").tag("letter")
                                Text("A4").tag("a4")
                                Text("A5").tag("a5")
                            }
                            .pickerStyle(.segmented)
                            Toggle("Landscape", isOn: $landscape)
                                .fixedSize()
                        }
                    }
                }
                .padding(20)
            }
            .background(BrandBackdrop(intensity: 0.35))
            .navigationTitle(mode == .notebook ? "New notebook" : "New note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .buttonStyle(.glassProminent)
                }
            }
            .onAppear { accent = app.nextAccent() }
        }
    }

    private var displayTitle: String { title.isEmpty ? (mode == .notebook ? "My Notebook" : "Note") : title }

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
        let paperRef = PaperRef(template: paper)
        switch mode {
        case .notebook:
            app.createNotebook(title: displayTitle, cover: cover, accent: accent, paper: paperRef, titlePage: titlePage, size: size, in: folder)
        case .note:
            app.createNote(title: displayTitle, accent: accent, paper: paperRef, size: size, in: folder)
        }
        dismiss()
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }
}

func selectionRing(_ selected: Bool) -> some View {
    RoundedRectangle(cornerRadius: 8)
        .stroke(Brand.pink, lineWidth: selected ? 3 : 0)
        .padding(-4)
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
                Text(category).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88, maximum: 120), spacing: 14)], spacing: 14) {
                    ForEach(papers.filter { $0.paper.category == category }, id: \.ref) { entry in
                        VStack(spacing: 6) {
                            PaperPreview(template: entry.paper, packID: entry.ref.packID, accent: accent, parameters: entry.ref == selection ? parameters : [:])
                                .overlay(selectionRing(entry.ref == selection))
                            Text(entry.paper.name).font(.caption).lineLimit(1)
                        }
                        .onTapGesture { selection = entry.ref }
                    }
                }
            }
        }
    }
}
