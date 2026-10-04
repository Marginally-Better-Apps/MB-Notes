#if canImport(UIKit) && canImport(PencilKit)
import CoreText
import PencilKit
import UIKit

/// Exports a note as a PDF that other apps can search and select.
///
/// Paper, imported pages, and typed text stay vector. Ink is embedded as an
/// image, and recognized handwriting is drawn over it as invisible text, the
/// same technique scanners use for OCR layers.
public struct PDFExporter {
    public struct Options: Sendable {
        public var includeRecognizedText: Bool
        public var includeTranscripts: Bool
        /// Ink rasterization density relative to page points.
        public var inkScale: CGFloat

        public init(includeRecognizedText: Bool = true, includeTranscripts: Bool = false, inkScale: CGFloat = 3) {
            self.includeRecognizedText = includeRecognizedText
            self.includeTranscripts = includeTranscripts
            self.inkScale = inkScale
        }
    }

    public let renderer: PageRenderer

    public init(renderer: PageRenderer) {
        self.renderer = renderer
    }

    /// Writes the PDF to a temporary file and returns its URL.
    public func export(options: Options = Options(), inkOverrides: [UUID: PKDrawing] = [:]) throws -> URL {
        let manifest = renderer.manifest
        let name = manifest.title.isEmpty ? "Untitled" : manifest.title
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name.replacingOccurrences(of: "/", with: "-")).pdf")
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: name,
            kCGPDFContextCreator as String: "MB Notes",
        ]
        let firstSize = manifest.pages.first.map { CGSize(width: $0.size.width, height: $0.size.height) } ?? CGSize(width: 612, height: 792)
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: firstSize), format: format)
        try pdf.writePDF(to: url) { context in
            for page in manifest.pages {
                let rect = CGRect(x: 0, y: 0, width: page.size.width, height: page.size.height)
                context.beginPage(withBounds: rect, pageInfo: [:])
                let ctx = context.cgContext
                renderer.drawBackground(page, in: ctx, rect: rect)
                renderer.drawElements(page, in: ctx, rect: rect)
                if let ink = inkOverrides[page.id] ?? renderer.ink(for: page) {
                    renderer.drawInk(ink, page: page, in: ctx, rect: rect, scale: options.inkScale)
                }
                if options.includeRecognizedText, let recognition = renderer.package.readRecognition(for: page.id) {
                    Self.drawInvisibleText(recognition.lines, in: ctx)
                }
            }
            if options.includeTranscripts {
                drawTranscriptPages(context: context, pageSize: firstSize)
            }
        }
        return url
    }

    /// Draws each line invisibly, stretched to its box so text selection lines up with the ink.
    static func drawInvisibleText(_ lines: [PageRecognition.Line], in ctx: CGContext) {
        for line in lines where !line.text.isEmpty {
            let box = CGRect(x: line.box.x, y: line.box.y, width: line.box.width, height: line.box.height)
            guard box.width > 1, box.height > 1 else { continue }
            let font = CTFontCreateWithName("Helvetica" as CFString, box.height * 0.8, nil)
            let attributed = NSAttributedString(string: line.text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            guard width > 0 else { continue }
            ctx.saveGState()
            ctx.setTextDrawingMode(.invisible)
            ctx.translateBy(x: box.minX, y: box.maxY - box.height * 0.2)
            ctx.scaleBy(x: box.width / CGFloat(width), y: -1)
            ctx.textPosition = .zero
            CTLineDraw(ctLine, ctx)
            ctx.restoreGState()
        }
    }

    private func drawTranscriptPages(context: UIGraphicsPDFRendererContext, pageSize: CGSize) {
        let package = renderer.package
        let transcripts = renderer.manifest.recordings.compactMap { recording in package.readTranscript(recording).map { (recording, $0) } }
        guard !transcripts.isEmpty else { return }
        let text = NSMutableAttributedString()
        for (recording, transcript) in transcripts {
            text.append(NSAttributedString(string: "\(recording.title)\n", attributes: [.font: UIFont.boldSystemFont(ofSize: 16)]))
            text.append(NSAttributedString(string: transcript.visibleText() + "\n\n", attributes: [.font: UIFont.systemFont(ofSize: 11)]))
        }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        var position = 0
        let margin: CGFloat = 54
        while position < text.length {
            let rect = CGRect(origin: .zero, size: pageSize)
            context.beginPage(withBounds: rect, pageInfo: [:])
            let ctx = context.cgContext
            let box = rect.insetBy(dx: margin, dy: margin)
            ctx.saveGState()
            ctx.translateBy(x: box.minX, y: box.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textMatrix = .identity
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: position, length: 0), CGPath(rect: CGRect(origin: .zero, size: box.size), transform: nil), nil)
            CTFrameDraw(frame, ctx)
            ctx.restoreGState()
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { break }
            position += visible.length
        }
    }
}
#endif
