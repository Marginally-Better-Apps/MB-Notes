import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import NoteEngine

/// Validates the built-in pack the app ships. Set MBNOTES_PREVIEW_DIR to also
/// write a PNG of every paper and cover for visual review.
@Suite struct CorePackTests {
    static let packURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("MBNotes/Resources/Packs/core.mbpack")

    @Test func corePackLoadsCleanly() throws {
        let pack = try PackRegistry.load(from: Self.packURL, builtIn: true)
        #expect(pack.id == CorePack.id)
        #expect(pack.papers.contains { $0.id == "blank" })
        #expect(pack.papers.contains { $0.role == .title })
        #expect(!pack.covers.isEmpty && !pack.stickers.isEmpty && !pack.palettes.isEmpty)
        #expect(Set(pack.papers.map(\.id)).count == pack.papers.count, "paper ids must be unique")
        #expect(Set(pack.stickers.map(\.id)).count == pack.stickers.count, "sticker ids must be unique")
        let knownTypes: Set<String> = ["fill", "gradient", "hlines", "vlines", "grid", "dots", "isometric", "staff", "rect", "ellipse", "line", "path", "text", "star", "image", "pdf"]
        let layers = pack.papers.flatMap(\.layers) + pack.covers.flatMap(\.layers) + pack.stickers.flatMap { $0.layers ?? [] }
        for layer in layers {
            #expect(knownTypes.contains(layer.type), "unknown layer type \(layer.type)")
        }
        // Everything built in was made for MB Notes; nothing borrows third-party art.
        #expect(pack.stickers.allSatisfy { $0.emoji != nil || $0.layers != nil }, "core stickers are emoji or vector layers only")
        #expect(pack.manifest.license == "CC0-1.0")
        #expect(FileManager.default.fileExists(atPath: Self.packURL.appendingPathComponent("LICENSE").path))
    }

    @Test func starPathHasOnePointPerVertex() {
        let star = TemplateRenderer.starPath(in: CGRect(x: 0, y: 0, width: 100, height: 100), points: 5, innerRatio: 0.5)
        #expect(star.boundingBox.minY == 0)
        let hexagon = TemplateRenderer.starPath(in: CGRect(x: 0, y: 0, width: 100, height: 100), points: 6, innerRatio: 1)
        #expect(abs(hexagon.boundingBox.width - 86.6) < 0.1)
    }

    @Test func renderPreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["MBNOTES_PREVIEW_DIR"] else { return }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let pack = try PackRegistry.load(from: Self.packURL, builtIn: true)
        let env = RenderEnvironment(palette: ColorSpec.Palette(accent: ColorSpec.hex("#F76CA0")!), variables: ["title": "Biology 101", "subtitle": "Fall semester", "date": "October 3, 2026", "year": "2026"])
        for paper in pack.papers {
            try render(size: CGSize(width: 612, height: 792), to: out.appendingPathComponent("paper-\(paper.id).png")) { ctx, rect in
                TemplateRenderer.drawPaper(paper, in: ctx, rect: rect, environment: env)
            }
        }
        for cover in pack.covers {
            try render(size: CGSize(width: 300, height: 400), to: out.appendingPathComponent("cover-\(cover.id).png")) { ctx, rect in
                TemplateRenderer.drawCover(cover, in: ctx, rect: rect, environment: env)
            }
        }
        let labels = pack.stickers.filter { $0.layers != nil }
        try render(size: CGSize(width: 600, height: 100 * CGFloat((labels.count + 3) / 4)), to: out.appendingPathComponent("stickers.png")) { ctx, _ in
            for (i, sticker) in labels.enumerated() {
                let rect = CGRect(x: CGFloat(i % 4) * 150 + 10, y: CGFloat(i / 4) * 100 + 10, width: 130, height: 80)
                TemplateRenderer.drawSticker(sticker, in: ctx, rect: rect, environment: env)
            }
        }
    }

    private func render(size: CGSize, to url: URL, draw: (CGContext, CGRect) -> Void) throws {
        let scale: CGFloat = 1
        let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.85, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        // Match UIKit: origin at top-left.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: scale, y: -scale)
        draw(ctx, CGRect(origin: .zero, size: size))
        let image = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}

@Suite struct ExamplePackTests {
    @Test func examplePackLoadsAndFindsItsImages() throws {
        let url = CorePackTests.packURL
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("examples/packs/cozy-cafe.mbpack")
        let pack = try PackRegistry.load(from: url)
        #expect(pack.papers.count == 2)
        #expect(pack.papers.contains { $0.role == .title })
        #expect(pack.assetURL("images/croissant.png") != nil)
        #expect(pack.assetURL("../pack.json") == nil)
    }
}
