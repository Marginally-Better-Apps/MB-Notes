import Foundation

/// Builds new notes from pack content.
public enum NoteFactory {
    public static func notebook(
        title: String,
        cover: ContentRef,
        accentColor: String,
        paper: PaperRef,
        titlePage: ContentRef?,
        size: PageSize,
        catalog: PackCatalog
    ) -> NoteManifest {
        var pages: [PageSpec] = []
        if let titlePage {
            pages.append(PageSpec(size: size, paper: PaperRef(template: titlePage)))
        }
        pages.append(PageSpec(size: size, paper: paper))
        var manifest = NoteManifest(
            title: title,
            kind: .notebook,
            accentColor: accentColor,
            cover: CoverSpec(design: cover),
            defaultPaper: paper,
            pages: pages
        )
        embedResources(in: &manifest, catalog: catalog)
        return manifest
    }

    public static func note(title: String, accentColor: String, paper: PaperRef, size: PageSize, catalog: PackCatalog) -> NoteManifest {
        var manifest = NoteManifest(
            title: title,
            kind: .note,
            accentColor: accentColor,
            defaultPaper: paper,
            pages: [PageSpec(size: size, paper: paper)]
        )
        embedResources(in: &manifest, catalog: catalog)
        return manifest
    }

    /// The page size a template asks for, falling back to the user's preference.
    public static func pageSize(for paper: ContentRef, preferred: PageSize, catalog: PackCatalog) -> PageSize {
        catalog.paper(paper)?.size ?? preferred
    }

    /// Copies every template, cover, and sticker the note references into `embedded`,
    /// and drops snapshots nothing references anymore.
    public static func embedResources(in manifest: inout NoteManifest, catalog: PackCatalog) {
        var papers: [String: PaperTemplate] = [:]
        var covers: [String: CoverDesign] = [:]
        var stickers: [String: StickerDefinition] = [:]

        var paperRefs = Set(manifest.pages.map(\.paper.template))
        paperRefs.insert(manifest.defaultPaper.template)
        for ref in paperRefs {
            if let paper = catalog.paper(ref) ?? manifest.embedded.papers[ref.rawValue] { papers[ref.rawValue] = paper }
        }
        if let cover = manifest.cover {
            if let design = catalog.cover(cover.design) ?? manifest.embedded.covers[cover.design.rawValue] {
                covers[cover.design.rawValue] = design
            }
            for placed in cover.stickers {
                if let sticker = catalog.sticker(placed.sticker) ?? manifest.embedded.stickers[placed.sticker.rawValue] {
                    stickers[placed.sticker.rawValue] = sticker
                }
            }
        }
        for element in manifest.pages.flatMap(\.elements) {
            guard let ref = element.sticker else { continue }
            if let sticker = catalog.sticker(ref) ?? manifest.embedded.stickers[ref.rawValue] { stickers[ref.rawValue] = sticker }
        }
        manifest.embedded = EmbeddedResources(papers: papers, covers: covers, stickers: stickers)
    }
}
