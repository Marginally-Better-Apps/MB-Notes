import CoreGraphics
import CoreText
import Foundation
import ImageIO
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Everything a layer may refer to while drawing.
public struct RenderEnvironment: @unchecked Sendable {
    public var palette: ColorSpec.Palette
    /// Values for `{{placeholders}}` in text layers, such as `title` and `date`.
    public var variables: [String: String]
    /// Resolved template parameters for `$name` lengths.
    public var parameters: [String: Double]
    /// Resolves a pack-relative asset path.
    public var assetURL: (String) -> URL?

    public init(palette: ColorSpec.Palette = .standard, variables: [String: String] = [:], parameters: [String: Double] = [:], assetURL: @escaping (String) -> URL? = { _ in nil }) {
        self.palette = palette
        self.variables = variables
        self.parameters = parameters
        self.assetURL = assetURL
    }
}

/// Draws pack layers into a Core Graphics context with a top-left origin
/// (the convention of UIKit image, PDF, and view contexts).
public enum TemplateRenderer {
    // MARK: Entry points

    /// Draws a paper template filling `rect`.
    public static func drawPaper(_ template: PaperTemplate, in ctx: CGContext, rect: CGRect, environment: RenderEnvironment, backgroundOverride: String? = nil) {
        var env = environment
        env.parameters = template.parameters.mapValues(\.defaultValue).merging(environment.parameters) { _, override in override }
        let background = ColorSpec.color(backgroundOverride ?? template.background, palette: env.palette) ?? env.palette.paper
        env.palette.paper = background
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.setFillColor(background)
        ctx.fill(CGRect(origin: .zero, size: rect.size))
        drawLayers(template.layers, in: ctx, size: rect.size, environment: env)
        ctx.restoreGState()
    }

    /// Draws a cover design scaled to fill `rect`.
    public static func drawCover(_ design: CoverDesign, in ctx: CGContext, rect: CGRect, environment: RenderEnvironment) {
        let canvas = CoverDesign.canvasSize
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / canvas.width, y: rect.height / canvas.height)
        let size = CGSize(width: canvas.width, height: canvas.height)
        if let background = ColorSpec.color(design.background, palette: environment.palette) {
            ctx.setFillColor(background)
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        drawLayers(design.layers, in: ctx, size: size, environment: environment)
        ctx.restoreGState()
    }

    /// Draws a sticker aspect-fit inside `rect`.
    public static func drawSticker(_ sticker: StickerDefinition, in ctx: CGContext, rect: CGRect, environment: RenderEnvironment) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if let emoji = sticker.emoji {
            drawCenteredText(emoji, in: ctx, rect: rect, fontSize: rect.height * 0.82, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            return
        }
        if let image = sticker.image, let url = environment.assetURL(image) {
            drawAsset(url, page: 0, in: ctx, rect: rect, fill: false)
            return
        }
        if let layers = sticker.layers {
            let canvas = sticker.canvas ?? PageSize(width: 100, height: 100)
            let scale = min(rect.width / canvas.width, rect.height / canvas.height)
            ctx.translateBy(x: rect.midX - canvas.width * scale / 2, y: rect.midY - canvas.height * scale / 2)
            ctx.scaleBy(x: scale, y: scale)
            drawLayers(layers, in: ctx, size: CGSize(width: canvas.width, height: canvas.height), environment: environment)
        }
    }

    // MARK: Layers

    public static func drawLayers(_ layers: [Layer], in ctx: CGContext, size: CGSize, environment env: RenderEnvironment) {
        for layer in layers {
            let count = max(1, layer.repeat?.count ?? 1)
            let dx = layer.repeat?.dx?.resolve(axis: size.width, parameters: env.parameters) ?? 0
            let dy = layer.repeat?.dy?.resolve(axis: size.height, parameters: env.parameters) ?? 0
            for i in 0..<min(count, 2000) {
                ctx.saveGState()
                ctx.translateBy(x: dx * CGFloat(i), y: dy * CGFloat(i))
                if let opacity = layer.opacity { ctx.setAlpha(CGFloat(opacity)) }
                if let rotation = layer.rotation, rotation != 0 {
                    let frame = self.frame(layer, size: size, env: env)
                    ctx.translateBy(x: frame.midX, y: frame.midY)
                    ctx.rotate(by: CGFloat(rotation) * .pi / 180)
                    ctx.translateBy(x: -frame.midX, y: -frame.midY)
                }
                draw(layer, in: ctx, size: size, env: env)
                ctx.restoreGState()
            }
        }
    }

    private static func draw(_ layer: Layer, in ctx: CGContext, size: CGSize, env: RenderEnvironment) {
        let p = env.parameters
        func len(_ l: Length?, axis: CGFloat, _ fallback: CGFloat) -> CGFloat {
            l.map { CGFloat($0.resolve(axis: Double(axis), parameters: p)) } ?? fallback
        }
        func color(_ spec: String?, _ fallback: CGColor? = nil) -> CGColor? {
            ColorSpec.color(spec, palette: env.palette) ?? fallback
        }
        let insetTop = len(layer.top, axis: size.height, 0)
        let insetBottom = len(layer.bottom, axis: size.height, 0)
        let insetLeft = len(layer.left, axis: size.width, 0)
        let insetRight = len(layer.right, axis: size.width, 0)
        let lineColor = color(layer.color, CGColor(srgbRed: 0.63, green: 0.77, blue: 0.92, alpha: 1))!
        let lineWidth = CGFloat(layer.lineWidth ?? 0.75)

        func strokeLines(_ build: (CGMutablePath) -> Void, color: CGColor = lineColor, width: CGFloat = lineWidth) {
            let path = CGMutablePath()
            build(path)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(width)
            ctx.setLineDash(phase: 0, lengths: (layer.dash ?? []).map { CGFloat($0) })
            ctx.addPath(path)
            ctx.strokePath()
        }

        switch layer.type {
        case "fill":
            ctx.setFillColor(color(layer.color ?? layer.fill, env.palette.paper)!)
            ctx.fill(frame(layer, size: size, env: env))

        case "gradient":
            let colors = (layer.colors ?? ["accentLight", "accent"]).compactMap { color($0) }
            guard colors.count >= 2, let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil) else { return }
            let rect = frame(layer, size: size, env: env)
            let radians = CGFloat(layer.angle ?? 90) * .pi / 180
            let half = CGPoint(x: cos(radians) * rect.width / 2, y: sin(radians) * rect.height / 2)
            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.midX - half.x, y: rect.midY - half.y), end: CGPoint(x: rect.midX + half.x, y: rect.midY + half.y), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()

        case "hlines":
            let spacing = max(2, len(layer.spacing, axis: size.height, 24))
            let start = layer.top == nil ? spacing : insetTop
            strokeLines { path in
                var y = start
                while y <= size.height - insetBottom + 0.01 {
                    path.move(to: CGPoint(x: insetLeft, y: y))
                    path.addLine(to: CGPoint(x: size.width - insetRight, y: y))
                    y += spacing
                }
            }

        case "vlines":
            let spacing = max(2, len(layer.spacing, axis: size.width, 24))
            let start = layer.left == nil ? spacing : insetLeft
            strokeLines { path in
                var x = start
                while x <= size.width - insetRight + 0.01 {
                    path.move(to: CGPoint(x: x, y: insetTop))
                    path.addLine(to: CGPoint(x: x, y: size.height - insetBottom))
                    x += spacing
                }
            }

        case "grid":
            let spacing = max(2, len(layer.spacing, axis: size.width, 20))
            let major = layer.majorEvery ?? 0
            let majorColor = color(layer.majorColor, lineColor)!
            let majorWidth = CGFloat(layer.majorWidth ?? Double(lineWidth) * 1.8)
            for pass in [false, true] where !pass || major > 0 {
                strokeLines({ path in
                    var i = 0
                    var x = insetLeft
                    while x <= size.width - insetRight + 0.01 {
                        if (major > 0 && i % major == 0) == pass {
                            path.move(to: CGPoint(x: x, y: insetTop))
                            path.addLine(to: CGPoint(x: x, y: size.height - insetBottom))
                        }
                        x += spacing
                        i += 1
                    }
                    i = 0
                    var y = insetTop
                    while y <= size.height - insetBottom + 0.01 {
                        if (major > 0 && i % major == 0) == pass {
                            path.move(to: CGPoint(x: insetLeft, y: y))
                            path.addLine(to: CGPoint(x: size.width - insetRight, y: y))
                        }
                        y += spacing
                        i += 1
                    }
                }, color: pass ? majorColor : lineColor, width: pass ? majorWidth : lineWidth)
            }

        case "dots":
            let spacing = max(2, len(layer.spacing, axis: size.width, 20))
            let radius = len(layer.radius, axis: size.width, 1.1)
            ctx.setFillColor(color(layer.color, CGColor(srgbRed: 0.6, green: 0.62, blue: 0.7, alpha: 1))!)
            var y = layer.top == nil ? spacing : insetTop
            while y <= size.height - insetBottom + 0.01 {
                var x = layer.left == nil ? spacing : insetLeft
                while x <= size.width - insetRight + 0.01 {
                    ctx.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                    x += spacing
                }
                y += spacing
            }
            ctx.fillPath()

        case "isometric":
            let spacing = max(4, len(layer.spacing, axis: size.width, 24))
            let rowHeight = spacing * sqrt(3) / 2
            let area = CGRect(x: insetLeft, y: insetTop, width: size.width - insetLeft - insetRight, height: size.height - insetTop - insetBottom)
            if layer.style == "dots" {
                ctx.setFillColor(lineColor)
                let r = len(layer.radius, axis: size.width, 1.1)
                var row = 0
                var y = area.minY
                while y <= area.maxY {
                    var x = area.minX + (row % 2 == 0 ? 0 : spacing / 2)
                    while x <= area.maxX {
                        ctx.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                        x += spacing
                    }
                    y += rowHeight
                    row += 1
                }
                ctx.fillPath()
            } else {
                ctx.saveGState()
                ctx.clip(to: area)
                strokeLines { path in
                    var y = area.minY
                    while y <= area.maxY {
                        path.move(to: CGPoint(x: area.minX, y: y))
                        path.addLine(to: CGPoint(x: area.maxX, y: y))
                        y += rowHeight
                    }
                    // Two diagonal families at ±60°, spanning enough offsets to cover the area.
                    let run = area.height / tan(.pi / 3)
                    var x = area.minX - run
                    while x <= area.maxX + run {
                        path.move(to: CGPoint(x: x, y: area.minY))
                        path.addLine(to: CGPoint(x: x + run, y: area.maxY))
                        path.move(to: CGPoint(x: x + run, y: area.minY))
                        path.addLine(to: CGPoint(x: x, y: area.maxY))
                        x += spacing
                    }
                }
                ctx.restoreGState()
            }

        case "staff":
            let gap = max(2, len(layer.spacing, axis: size.height, 8))
            let staffGap = len(layer.staffGap, axis: size.height, 48)
            strokeLines { path in
                var y = layer.top == nil ? 72 : insetTop
                while y + gap * 4 <= size.height - insetBottom {
                    for line in 0..<5 {
                        let ly = y + CGFloat(line) * gap
                        path.move(to: CGPoint(x: insetLeft, y: ly))
                        path.addLine(to: CGPoint(x: size.width - insetRight, y: ly))
                    }
                    y += gap * 4 + staffGap
                }
            }

        case "rect", "ellipse":
            let rect = frame(layer, size: size, env: env)
            let path: CGPath
            if layer.type == "ellipse" {
                path = CGPath(ellipseIn: rect, transform: nil)
            } else {
                let r = min(len(layer.cornerRadius, axis: min(rect.width, rect.height), 0), min(rect.width, rect.height) / 2)
                path = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
            }
            fillAndStroke(path, layer: layer, in: ctx, env: env)

        case "star":
            let rect = frame(layer, size: size, env: env)
            fillAndStroke(starPath(in: rect, points: max(3, layer.points ?? 5), innerRatio: layer.innerRatio ?? 0.5), layer: layer, in: ctx, env: env)

        case "line":
            strokeLines({ path in
                path.move(to: CGPoint(x: len(layer.x1, axis: size.width, 0), y: len(layer.y1, axis: size.height, 0)))
                path.addLine(to: CGPoint(x: len(layer.x2, axis: size.width, size.width), y: len(layer.y2, axis: size.height, 0)))
            }, color: color(layer.color ?? layer.stroke, lineColor)!, width: CGFloat(layer.lineWidth ?? 1))

        case "path":
            guard let d = layer.d else { return }
            let raw = SVGPath.path(from: d)
            let box = layer.viewBox.flatMap { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil } ?? raw.boundingBoxOfPath
            let target = frame(layer, size: size, env: env)
            guard box.width > 0 || box.height > 0 else { return }
            let scale = min(target.width / max(box.width, 0.001), target.height / max(box.height, 0.001))
            var transform = CGAffineTransform(translationX: target.midX, y: target.midY)
                .scaledBy(x: scale, y: scale)
                .translatedBy(x: -box.midX, y: -box.midY)
            guard let path = raw.copy(using: &transform) else { return }
            fillAndStroke(path, layer: layer, in: ctx, env: env)

        case "text":
            guard let template = layer.text else { return }
            let text = substitute(template, variables: env.variables)
            guard !text.isEmpty else { return }
            drawText(text, layer: layer, in: ctx, rect: frame(layer, size: size, env: env), env: env)

        case "image", "pdf":
            guard let src = layer.src, let url = env.assetURL(src) else { return }
            drawAsset(url, page: layer.page ?? 0, in: ctx, rect: frame(layer, size: size, env: env), fill: layer.style == "fill")

        default:
            break
        }
    }

    /// The layer's `x y width height` box, defaulting to the whole canvas.
    static func frame(_ layer: Layer, size: CGSize, env: RenderEnvironment) -> CGRect {
        let p = env.parameters
        let x = layer.x?.resolve(axis: size.width, parameters: p) ?? 0
        let y = layer.y?.resolve(axis: size.height, parameters: p) ?? 0
        let w = layer.width?.resolve(axis: size.width, parameters: p) ?? (size.width - x)
        let h = layer.height?.resolve(axis: size.height, parameters: p) ?? (size.height - y)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// A star (or, with `innerRatio` 1, a regular polygon) with its first point at the top.
    public static func starPath(in rect: CGRect, points: Int, innerRatio: Double) -> CGPath {
        let path = CGMutablePath()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * CGFloat(min(max(innerRatio, 0.05), 1))
        let polygon = innerRatio >= 1
        let count = polygon ? points : points * 2
        for i in 0..<count {
            let radius = (polygon || i % 2 == 0) ? outer : inner
            let angle = -CGFloat.pi / 2 + CGFloat(i) * 2 * .pi / CGFloat(count)
            let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    private static func fillAndStroke(_ path: CGPath, layer: Layer, in ctx: CGContext, env: RenderEnvironment) {
        let fill = ColorSpec.color(layer.fill, palette: env.palette)
        let stroke = ColorSpec.color(layer.stroke ?? (layer.fill == nil ? layer.color : nil), palette: env.palette)
        if let fill {
            ctx.addPath(path)
            ctx.setFillColor(fill)
            ctx.fillPath()
        }
        if let stroke {
            ctx.addPath(path)
            ctx.setStrokeColor(stroke)
            ctx.setLineWidth(CGFloat(layer.lineWidth ?? 1))
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)
            ctx.setLineDash(phase: 0, lengths: (layer.dash ?? []).map { CGFloat($0) })
            ctx.strokePath()
        }
    }

    // MARK: Text

    public static func substitute(_ template: String, variables: [String: String]) -> String {
        guard template.contains("{{") else { return template }
        var result = template
        for (key, value) in variables {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        // Drop placeholders nobody filled in.
        while let open = result.range(of: "{{"), let close = result.range(of: "}}", range: open.upperBound..<result.endIndex) {
            result.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return result
    }

    public static func font(size: CGFloat, weight: String?, design: String?) -> CTFont {
        #if canImport(UIKit)
        let w: UIFont.Weight
        switch weight {
        case "light": w = .light
        case "medium": w = .medium
        case "semibold": w = .semibold
        case "bold": w = .bold
        case "heavy", "black": w = .heavy
        default: w = .regular
        }
        if design == "handwritten" {
            let name = (weight == "bold" || weight == "heavy") ? "Noteworthy-Bold" : "Noteworthy-Light"
            return CTFontCreateWithName(name as CFString, size, nil)
        }
        var descriptor = UIFont.systemFont(ofSize: size, weight: w).fontDescriptor
        switch design {
        case "rounded": descriptor = descriptor.withDesign(.rounded) ?? descriptor
        case "serif": descriptor = descriptor.withDesign(.serif) ?? descriptor
        case "monospaced": descriptor = descriptor.withDesign(.monospaced) ?? descriptor
        default: break
        }
        return UIFont(descriptor: descriptor, size: size) as CTFont
        #else
        let bold = weight == "bold" || weight == "heavy" || weight == "semibold"
        return CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        #endif
    }

    private static func drawText(_ text: String, layer: Layer, in ctx: CGContext, rect: CGRect, env: RenderEnvironment) {
        let font = font(size: CGFloat(layer.fontSize ?? 17), weight: layer.weight, design: layer.design)
        let color = ColorSpec.color(layer.color, palette: env.palette) ?? env.palette.ink
        var alignment: CTTextAlignment
        switch layer.align {
        case "center": alignment = .center
        case "right": alignment = .right
        default: alignment = .left
        }
        let paragraph = withUnsafeBytes(of: &alignment) { bytes in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: bytes.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
        ])
        drawAttributed(attributed, in: ctx, rect: rect, verticallyCentered: layer.style == "middle")
    }

    static func drawCenteredText(_ text: String, in ctx: CGContext, rect: CGRect, fontSize: CGFloat, color: CGColor) {
        var alignment = CTTextAlignment.center
        let paragraph = withUnsafeBytes(of: &alignment) { bytes in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: bytes.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("AppleColorEmoji" as CFString, fontSize, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
        ])
        drawAttributed(attributed, in: ctx, rect: rect.insetBy(dx: -rect.width, dy: 0), verticallyCentered: true)
    }

    static func drawAttributed(_ text: NSAttributedString, in ctx: CGContext, rect: CGRect, verticallyCentered: Bool) {
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        var box = rect
        if verticallyCentered {
            let fit = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil, CGSize(width: rect.width, height: .greatestFiniteMagnitude), nil)
            box = CGRect(x: rect.minX, y: rect.midY - fit.height / 2, width: rect.width, height: fit.height + 1)
        }
        ctx.saveGState()
        ctx.translateBy(x: box.minX, y: box.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: CGRect(origin: .zero, size: box.size), transform: nil), nil)
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }

    // MARK: Assets

    private final class AssetCache: @unchecked Sendable {
        let images = NSCache<NSURL, CGImage>()
        let pdfs = NSCache<NSURL, CGPDFDocument>()
    }
    private static let cache = AssetCache()

    /// Draws a PNG, JPEG, or PDF page into `rect`, aspect-fit (or aspect-fill when `fill`).
    public static func drawAsset(_ url: URL, page: Int, in ctx: CGContext, rect: CGRect, fill: Bool) {
        if url.pathExtension.lowercased() == "pdf" {
            let document = cache.pdfs.object(forKey: url as NSURL) ?? CGPDFDocument(url as CFURL)
            guard let document, let pdfPage = document.page(at: page + 1) else { return }
            cache.pdfs.setObject(document, forKey: url as NSURL)
            drawPDFPage(pdfPage, in: ctx, rect: rect)
            return
        }
        let image: CGImage? = cache.images.object(forKey: url as NSURL) ?? {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }()
        guard let image else { return }
        cache.images.setObject(image, forKey: url as NSURL)
        drawImage(image, in: ctx, rect: rect, fill: fill)
    }

    public static func drawImage(_ image: CGImage, in ctx: CGContext, rect: CGRect, fill: Bool) {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        guard iw > 0, ih > 0 else { return }
        let scale = fill ? max(rect.width / iw, rect.height / ih) : min(rect.width / iw, rect.height / ih)
        let target = CGRect(x: rect.midX - iw * scale / 2, y: rect.midY - ih * scale / 2, width: iw * scale, height: ih * scale)
        ctx.saveGState()
        if fill { ctx.clip(to: rect) }
        ctx.translateBy(x: target.minX, y: target.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: target.size))
        ctx.restoreGState()
    }

    /// Draws a PDF page aspect-fit into `rect` in a top-left-origin context.
    public static func drawPDFPage(_ page: CGPDFPage, in ctx: CGContext, rect: CGRect) {
        let box = page.getBoxRect(.cropBox)
        let rotated = page.rotationAngle % 180 != 0
        let pageSize = rotated ? CGSize(width: box.height, height: box.width) : box.size
        guard pageSize.width > 0, pageSize.height > 0 else { return }
        let scale = min(rect.width / pageSize.width, rect.height / pageSize.height)
        let target = CGRect(x: rect.midX - pageSize.width * scale / 2, y: rect.midY - pageSize.height * scale / 2, width: pageSize.width * scale, height: pageSize.height * scale)
        ctx.saveGState()
        ctx.translateBy(x: target.minX, y: target.maxY)
        ctx.scaleBy(x: scale, y: -scale)
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: pageSize), rotate: 0, preserveAspectRatio: true))
        ctx.clip(to: box)
        ctx.drawPDFPage(page)
        ctx.restoreGState()
    }
}
