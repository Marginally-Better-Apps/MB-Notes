#if canImport(UIKit) && canImport(PencilKit)
import PencilKit
import UIKit

/// Draws complete pages: paper, imported document page, elements, and ink.
public struct PageRenderer: @unchecked Sendable {
    public let package: NotePackage
    public let manifest: NoteManifest
    public let catalog: PackCatalog

    public init(package: NotePackage, manifest: NoteManifest, catalog: PackCatalog) {
        self.package = package
        self.manifest = manifest
        self.catalog = catalog
    }

    public static func environment(for manifest: NoteManifest, page: PageSpec?, pageNumber: Int?, catalog: PackCatalog, packID: String? = nil) -> RenderEnvironment {
        let accent = ColorSpec.hex(manifest.accentColor) ?? ColorSpec.Palette.standard.accent
        var variables: [String: String] = [
            "title": manifest.title,
            "subtitle": manifest.cover?.subtitle ?? "",
            "date": manifest.createdAt.formatted(date: .long, time: .omitted),
            "year": manifest.createdAt.formatted(.dateTime.year()),
        ]
        if let pageNumber { variables["page"] = String(pageNumber) }
        let parameters = page?.paper.parameters ?? [:]
        let resolvedPack = packID ?? page?.paper.template.packID
        return RenderEnvironment(
            palette: ColorSpec.Palette(accent: accent),
            variables: variables,
            parameters: parameters,
            assetURL: { path in resolvedPack.flatMap { catalog.assetURL(packID: $0, path: path) } }
        )
    }

    public func environment(for page: PageSpec) -> RenderEnvironment {
        let number = (manifest.pages.firstIndex { $0.id == page.id } ?? 0) + 1
        return Self.environment(for: manifest, page: page, pageNumber: number, catalog: catalog)
    }

    /// Paper and any imported document page.
    public func drawBackground(_ page: PageSpec, in ctx: CGContext, rect: CGRect) {
        let template = catalog.resolvePaper(page.paper.template, embedded: manifest.embedded)
        TemplateRenderer.drawPaper(template, in: ctx, rect: rect, environment: environment(for: page), backgroundOverride: page.paper.background)
        if let source = page.source, let url = package.fileURL(source.file), let document = SourceDocumentCache.shared.document(at: url),
           let pdfPage = document.page(at: source.pageIndex + 1) {
            TemplateRenderer.drawPDFPage(pdfPage, in: ctx, rect: rect)
        }
    }

    /// Text boxes, stickers, and images.
    public func drawElements(_ page: PageSpec, in ctx: CGContext, rect: CGRect) {
        let scale = rect.width / page.size.width
        for element in page.elements {
            let frame = CGRect(
                x: rect.minX + element.frame.x * scale,
                y: rect.minY + element.frame.y * scale,
                width: element.frame.width * scale,
                height: element.frame.height * scale
            )
            ctx.saveGState()
            if element.rotation != 0 {
                ctx.translateBy(x: frame.midX, y: frame.midY)
                ctx.rotate(by: element.rotation)
                ctx.translateBy(x: -frame.midX, y: -frame.midY)
            }
            switch element.kind {
            case .text:
                guard let text = element.text else { break }
                UIGraphicsPushContext(ctx)
                Self.attributedString(for: text, scale: scale).draw(with: frame, options: [.usesLineFragmentOrigin], context: nil)
                UIGraphicsPopContext()
            case .sticker:
                guard let ref = element.sticker, let sticker = catalog.resolveSticker(ref, embedded: manifest.embedded) else { break }
                let env = Self.environment(for: manifest, page: page, pageNumber: nil, catalog: catalog, packID: ref.packID)
                TemplateRenderer.drawSticker(sticker, in: ctx, rect: frame, environment: env)
            case .image:
                guard let path = element.image, let url = package.fileURL(path) else { break }
                TemplateRenderer.drawAsset(url, page: 0, in: ctx, rect: frame, fill: false)
            }
            ctx.restoreGState()
        }
    }

    public static func attributedString(for text: TextContent, scale: CGFloat = 1) -> NSAttributedString {
        let size = CGFloat(text.fontSize) * scale
        let font = text.fontName.flatMap { UIFont(name: $0, size: size) } ?? UIFont.systemFont(ofSize: size)
        let paragraph = NSMutableParagraphStyle()
        switch text.alignment {
        case "center": paragraph.alignment = .center
        case "right": paragraph.alignment = .right
        default: paragraph.alignment = .left
        }
        let color = ColorSpec.hex(text.color).map { UIColor(cgColor: $0) } ?? .black
        return NSAttributedString(string: text.string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    public func ink(for page: PageSpec) -> PKDrawing? {
        guard let data = package.readInk(for: page.id) else { return nil }
        return try? PKDrawing(data: data)
    }

    /// Draws ink in light appearance so dark-mode ink colors never leak into exports.
    public func drawInk(_ drawing: PKDrawing, page: PageSpec, in ctx: CGContext, rect: CGRect, scale: CGFloat) {
        guard !drawing.strokes.isEmpty else { return }
        let bounds = CGRect(origin: .zero, size: CGSize(width: page.size.width, height: page.size.height))
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: bounds, scale: scale)
        }
        UIGraphicsPushContext(ctx)
        image.draw(in: rect)
        UIGraphicsPopContext()
    }

    /// A raster image of the whole page.
    public func image(for page: PageSpec, width: CGFloat, ink: PKDrawing? = nil, includeInk: Bool = true) -> UIImage {
        let scale = width / page.size.width
        let size = CGSize(width: width, height: page.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let rect = CGRect(origin: .zero, size: size)
            drawBackground(page, in: context.cgContext, rect: rect)
            drawElements(page, in: context.cgContext, rect: rect)
            if includeInk, let drawing = ink ?? self.ink(for: page) {
                drawInk(drawing, page: page, in: context.cgContext, rect: rect, scale: scale * 2)
            }
        }
    }

    /// Ink alone on white, used for handwriting recognition.
    public static func inkOnlyImage(_ drawing: PKDrawing, pageSize: PageSize, scale: CGFloat = 2) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: pageSize.width, height: pageSize.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(bounds)
            var ink = UIImage()
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                ink = drawing.image(from: bounds, scale: scale)
            }
            ink.draw(in: bounds)
        }
        return image.cgImage
    }

    /// The library thumbnail: a notebook's cover, or a note's first page.
    public func thumbnail(width: CGFloat) -> UIImage? {
        if manifest.kind == .notebook, let cover = manifest.cover {
            return Self.coverImage(cover, manifest: manifest, catalog: catalog, width: width)
        }
        guard let first = manifest.pages.first else { return nil }
        return image(for: first, width: width)
    }

    public static func coverImage(_ cover: CoverSpec, manifest: NoteManifest, catalog: PackCatalog, width: CGFloat) -> UIImage {
        let canvas = CoverDesign.canvasSize
        let size = CGSize(width: width, height: width * canvas.height / canvas.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let rect = CGRect(origin: .zero, size: size)
            let design = catalog.resolveCover(cover.design, embedded: manifest.embedded)
            let env = environment(for: manifest, page: nil, pageNumber: nil, catalog: catalog, packID: cover.design.packID)
            TemplateRenderer.drawCover(design, in: context.cgContext, rect: rect, environment: env)
            for placed in cover.stickers {
                guard let sticker = catalog.resolveSticker(placed.sticker, embedded: manifest.embedded) else { continue }
                let side = width * 0.28 * placed.scale
                let center = CGPoint(x: placed.x * size.width, y: placed.y * size.height)
                context.cgContext.saveGState()
                context.cgContext.translateBy(x: center.x, y: center.y)
                context.cgContext.rotate(by: placed.rotation)
                let stickerEnv = environment(for: manifest, page: nil, pageNumber: nil, catalog: catalog, packID: placed.sticker.packID)
                TemplateRenderer.drawSticker(sticker, in: context.cgContext, rect: CGRect(x: -side / 2, y: -side / 2, width: side, height: side), environment: stickerEnv)
                context.cgContext.restoreGState()
            }
        }
    }
}

/// Keeps imported PDFs open while pages scroll by.
public final class SourceDocumentCache: @unchecked Sendable {
    public static let shared = SourceDocumentCache()
    private let cache = NSCache<NSURL, CGPDFDocument>()

    public func document(at url: URL) -> CGPDFDocument? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let document = CGPDFDocument(url as CFURL) else { return nil }
        cache.setObject(document, forKey: url as NSURL)
        return document
    }
}
#endif
