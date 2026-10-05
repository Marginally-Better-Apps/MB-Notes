import NoteEngine
import SwiftUI
import UniformTypeIdentifiers

/// Installed content packs: browse, add, share, and remove.
struct PacksView: View {
    @Environment(AppModel.self) private var app
    @Environment(SceneModel.self) private var scene
    @State private var showImporter = false
    @State private var askingForLink = false
    @State private var link = ""
    @State private var pendingRemoval: LoadedPack?
    @State private var dropping = false

    var body: some View {
        List {
            Section {
                ForEach(app.catalog.packs) { pack in
                    NavigationLink { PackDetailView(pack: pack) } label: { PackRowLabel(pack: pack) }
                        .swipeActions {
                            if !pack.isBuiltIn {
                                Button(role: .destructive) { pendingRemoval = pack } label: { Label("Remove", systemImage: "trash") }
                            }
                            ShareLink(item: PackExport(registry: app.packs, packID: pack.id, name: pack.manifest.name), preview: SharePreview(pack.manifest.name)) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                        }
                        .contextMenu {
                            ShareLink(item: PackExport(registry: app.packs, packID: pack.id, name: pack.manifest.name), preview: SharePreview(pack.manifest.name)) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            if !pack.isBuiltIn {
                                Button(role: .destructive) { pendingRemoval = pack } label: { Label("Remove", systemImage: "trash") }
                            }
                        }
                }
            } footer: {
                Text("Packs add papers, notebook covers, stickers, colors, and folder icons. They're plain JSON and images, so anyone can make one. Open a .mbpack file from Files, AirDrop, or Safari, drop one here, or paste a link.")
            }

            if !app.packs.loadErrors.isEmpty {
                Section("Couldn't Load") {
                    ForEach(app.packs.loadErrors.keys.sorted(), id: \.self) { name in
                        VStack(alignment: .leading) {
                            Text(name)
                            Text(app.packs.loadErrors[name]?.localizedDescription ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                Link(destination: URL(string: "https://github.com/Marginally-Better-Apps/MB-Notes/blob/main/docs/PACKS.md")!) {
                    Label("How to Make a Pack", systemImage: "hammer")
                }
            } footer: {
                Text("Packs are made by their authors, who are responsible for their content and licensing. MB Notes doesn't review them.")
            }
        }
        .overlay {
            if dropping {
                ContentUnavailableView("Drop to Add Pack", systemImage: "shippingbox.and.arrow.backward")
                    .background(.regularMaterial)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await scene.importFiles(urls.filter(PackInstaller.looksLikePack), into: app.library.root) }
            return true
        } isTargeted: { dropping = $0 }
        .navigationTitle("Packs")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { showImporter = true } label: { Label("From Files…", systemImage: "folder") }
                    Button { link = ""; askingForLink = true } label: { Label("From Link…", systemImage: "link") }
                } label: {
                    Label("Add Pack", systemImage: "plus")
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.mbPack, .zip, .folder], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await scene.importFiles(urls, into: app.library.root) }
        }
        .alert("Add Pack from Link", isPresented: $askingForLink) {
            TextField("https://…/pack.mbpack", text: $link)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            Button("Cancel", role: .cancel) {}
            Button("Add") {
                guard let url = URL(string: link.trimmingCharacters(in: .whitespaces)) else { return }
                scene.handleOpenURL(URL(string: "mbnotes://install?url=\(url.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")!)
            }
        }
        .confirmationDialog("Remove “\(pendingRemoval?.manifest.name ?? "")”?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), titleVisibility: .visible) {
            Button("Remove Pack", role: .destructive) {
                if let pack = pendingRemoval {
                    do { try app.packs.remove(packID: pack.id) } catch { scene.show(error) }
                    app.reloadPacks()
                }
                pendingRemoval = nil
            }
        } message: {
            Text("Notes keep a copy of the papers, covers, and stickers they already use.")
        }
    }
}

private struct PackRowLabel: View {
    let pack: LoadedPack
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 12) {
            if let cover = pack.covers.first {
                CoverPreview(design: cover, packID: pack.id, accent: cover.defaultColor ?? AppTheme.current.accentHex, title: "")
                    .frame(width: 40)
            } else {
                RoundedRectangle(cornerRadius: Radius.thumb).fill(.quaternary).frame(width: 40, height: 53)
                    .overlay(Image(systemName: "shippingbox").foregroundStyle(.secondary))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(pack.manifest.name)
                Text(pack.summary).font(.caption).foregroundStyle(.secondary)
                if let author = pack.manifest.author {
                    Text("by \(author) · \(pack.manifest.version)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

extension LoadedPack {
    var summary: String {
        var parts: [String] = []
        if !papers.isEmpty { parts.append("\(papers.count) \(papers.count == 1 ? "paper" : "papers")") }
        if !covers.isEmpty { parts.append("\(covers.count) \(covers.count == 1 ? "cover" : "covers")") }
        if !stickers.isEmpty { parts.append("\(stickers.count) \(stickers.count == 1 ? "sticker" : "stickers")") }
        return parts.joined(separator: " · ")
    }
}

/// What a pack contains, before or after installing it.
struct PackContents: View {
    let pack: LoadedPack
    @Environment(AppModel.self) private var app

    var body: some View {
        if let description = pack.manifest.description {
            Text(description).foregroundStyle(.secondary)
        }
        if !pack.covers.isEmpty {
            Text("Covers").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(pack.covers) { cover in
                        CoverPreview(design: cover, packID: pack.id, accent: cover.defaultColor ?? AppTheme.current.accentHex, title: cover.name)
                            .frame(width: 90)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        if !pack.papers.isEmpty {
            Text("Papers").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 12)], spacing: 12) {
                ForEach(pack.papers) { paper in
                    VStack(spacing: 4) {
                        PaperPreview(template: paper, packID: pack.id, title: "Title")
                        Text(paper.name).font(.caption).lineLimit(1)
                    }
                }
            }
        }
        if !pack.stickers.isEmpty {
            Text("Stickers").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 10)], spacing: 10) {
                ForEach(pack.stickers) { sticker in
                    StickerCanvas(sticker: sticker, packRoot: pack.rootURL)
                        .frame(width: 48, height: 48)
                }
            }
        }
    }
}

/// Draws a sticker straight from its definition, for packs not yet in the catalog.
struct StickerCanvas: View {
    let sticker: StickerDefinition
    let packRoot: URL

    var body: some View {
        Canvas { context, size in
            context.withCGContext { cg in
                let env = RenderEnvironment(palette: .standard, assetURL: { path in
                    let url = packRoot.appendingPathComponent(path)
                    return FileManager.default.fileExists(atPath: url.path) ? url : nil
                })
                TemplateRenderer.drawSticker(sticker, in: cg, rect: CGRect(origin: .zero, size: size), environment: env)
            }
        }
    }
}

struct PackDetailView: View {
    let pack: LoadedPack

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PackContents(pack: pack)
                if let license = pack.manifest.license {
                    Label("License: \(license)", systemImage: "doc.text").font(.footnote).foregroundStyle(.secondary)
                }
                if let homepage = pack.manifest.homepage, let url = URL(string: homepage) {
                    Link(destination: url) { Label("Website", systemImage: "safari") }.font(.footnote)
                }
            }
            .padding(20)
        }
        .navigationTitle(pack.manifest.name)
    }
}

/// Shows what a pack contains and who made it, then asks before installing.
struct PackPreviewSheet: View {
    let preview: PackInstaller.Preview
    @Environment(AppModel.self) private var app
    @Environment(SceneModel.self) private var scene
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        if let author = preview.pack.manifest.author { Text("by \(author)") }
                        Text("·")
                        Text("Version \(preview.pack.manifest.version)")
                        Text("·")
                        Text(ByteCountFormatter.string(fromByteCount: preview.unpackedBytes, countStyle: .file))
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    if let installed = preview.installed {
                        Label(preview.changesAuthor
                              ? "Replaces the installed “\(installed.name)” by \(installed.author ?? "an unknown author") with a pack by a different author."
                              : "Updates “\(installed.name)” \(installed.version) → \(preview.pack.manifest.version).",
                              systemImage: preview.changesAuthor ? "exclamationmark.triangle" : "arrow.triangle.2.circlepath")
                            .font(.footnote)
                            .foregroundStyle(preview.changesAuthor ? .orange : .secondary)
                    }

                    PackContents(pack: preview.pack)

                    Text("This pack is by \(preview.pack.manifest.author ?? "an unknown author") and licensed \(preview.pack.manifest.license ?? "with no license given"). MB Notes doesn't review packs. Install only packs you trust, and respect the author's license.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .navigationTitle(preview.pack.manifest.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { PackInstaller.discard(preview); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(preview.isUpdate ? "Update" : "Install", role: .confirm) {
                        do {
                            try app.packs.install(preview)
                            app.reloadPacks()
                        } catch {
                            scene.show(error, title: "Couldn't install the pack")
                        }
                        dismiss()
                    }
                }
            }
        }
        .interactiveDismissDisabled()
    }
}
