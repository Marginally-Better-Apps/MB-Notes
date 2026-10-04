import NoteEngine
import SwiftUI
import UniformTypeIdentifiers

/// Installed content packs: browse, install, share, and remove.
struct PacksView: View {
    @Environment(AppModel.self) private var app
    @State private var showImporter = false
    @State private var shareItem: ShareItem?

    var body: some View {
        List {
            Section {
                ForEach(app.catalog.packs) { pack in
                    NavigationLink { PackDetailView(pack: pack) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: pack.isBuiltIn ? "star.square.fill" : "shippingbox.fill")
                                .font(.title2)
                                .foregroundStyle(Brand.gradient)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pack.manifest.name).font(.headline)
                                Text("\(pack.papers.count) papers · \(pack.covers.count) covers · \(pack.stickers.count) stickers")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let author = pack.manifest.author {
                                    Text("by \(author) · v\(pack.manifest.version)").font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    .swipeActions {
                        if !pack.isBuiltIn {
                            Button(role: .destructive) {
                                try? app.packs.remove(packID: pack.id)
                                app.reloadPacks()
                            } label: { Label("Remove", systemImage: "trash") }
                        }
                        Button {
                            if let url = try? app.packs.exportArchive(packID: pack.id) { shareItem = ShareItem(url: url) }
                        } label: { Label("Share", systemImage: "square.and.arrow.up") }
                            .tint(Brand.violet)
                    }
                }
            } footer: {
                Text("Packs add papers, notebook covers, stickers, colors, and folder icons. They're plain JSON and images, so anyone can make one. Open a .mbpack file from Files, AirDrop, or Safari to install it.")
            }

            if !app.packs.loadErrors.isEmpty {
                Section("Couldn't load") {
                    ForEach(app.packs.loadErrors.keys.sorted(), id: \.self) { name in
                        VStack(alignment: .leading) {
                            Text(name).font(.headline)
                            Text(app.packs.loadErrors[name]?.localizedDescription ?? "").font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            }

            Section {
                Link(destination: URL(string: "https://github.com/Marginally-Better-Apps/MB-Notes/blob/main/docs/PACKS.md")!) {
                    Label("How to make a pack", systemImage: "hammer.fill")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(BrandBackdrop(intensity: 0.4))
        .navigationTitle("Packs")
        .toolbar {
            Button { showImporter = true } label: { Label("Install pack", systemImage: "plus") }
                .buttonStyle(.glassProminent)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [UTType(exportedAs: "com.marginallybetter.notes.pack"), .zip, .folder], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await app.importFiles(urls, into: app.library.root) }
        }
        .sheet(item: $shareItem) { ShareSheet(items: [$0.url]) }
    }
}

struct PackDetailView: View {
    let pack: LoadedPack
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let description = pack.manifest.description {
                    Text(description).foregroundStyle(.secondary)
                }
                if let license = pack.manifest.license {
                    Label("License: \(license)", systemImage: "doc.text").font(.caption)
                }
                if !pack.covers.isEmpty {
                    Text("Covers").font(.headline)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(pack.covers) { cover in
                                CoverPreview(design: cover, packID: pack.id, accent: cover.defaultColor ?? "#F76CA0", title: cover.name)
                                    .frame(width: 100)
                            }
                        }
                        .padding(6)
                    }
                }
                if !pack.papers.isEmpty {
                    Text("Papers").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 14)], spacing: 14) {
                        ForEach(pack.papers) { paper in
                            VStack {
                                PaperPreview(template: paper, packID: pack.id, title: "Title")
                                Text(paper.name).font(.caption).lineLimit(1)
                            }
                        }
                    }
                }
                if !pack.stickers.isEmpty {
                    Text("Stickers").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 10)], spacing: 10) {
                        ForEach(pack.stickers) { sticker in
                            StickerView(ref: ContentRef(packID: pack.id, itemID: sticker.id), catalog: app.catalog)
                                .frame(width: 52, height: 52)
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle(pack.manifest.name)
    }
}

struct AboutView: View {
    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Image("IconPreview-Sunset")
                        .resizable()
                        .frame(width: 96, height: 96)
                        .clipShape(.rect(cornerRadius: 22))
                    Text("MB Notes").font(.title2.weight(.bold))
                    Text("Marginally better notes. Free and open source, for everyone.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical)
            }
            Section("Open source") {
                Link("Source code on GitHub", destination: URL(string: "https://github.com/Marginally-Better-Apps/MB-Notes")!)
                Link("Make a pack", destination: URL(string: "https://github.com/Marginally-Better-Apps/MB-Notes/blob/main/docs/PACKS.md")!)
                Text("MB Notes is released under the MIT License.")
            }
            Section {
                Link("Powered by Desert Ant Labs", destination: URL(string: "https://desertant.com")!)
                Text("Shape snapping, Voz transcription, Clear audio cleanup, Uhm filler detection, Gist tags, and Title suggestions use on-device models by Desert Ant Labs under the Desert Ant Labs Source-Available License. Their SDK sends an anonymous monthly-active-device count with no notes, audio, or other content.")
                    .font(.footnote)
                Text("Speaker labels use FluidAudio (Apache-2.0) with pyannote community models. Local language models run with MLX Swift (MIT) and come from Hugging Face under each model's own license.")
                    .font(.footnote)
            } header: {
                Text("Credits")
            }
            Section {
                Text("Your notes are plain files in the Files app under On My iPhone or iPad › MB Notes. Recordings, transcripts, and handwriting recognition stay on this device. AI features send note text only to the provider you choose, only when you use them.")
                    .font(.footnote)
            } header: {
                Text("Privacy")
            }
        }
        .navigationTitle("About")
    }
}
