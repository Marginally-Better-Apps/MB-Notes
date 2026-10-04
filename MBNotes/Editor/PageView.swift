import NoteEngine
import UIKit

/// Draws a page's background in tiles so it stays sharp at any zoom.
final class TiledBackgroundView: UIView {
    override class var layerClass: AnyClass { CATiledLayer.self }

    var page: PageSpec
    var renderer: PageRenderer

    init(page: PageSpec, renderer: PageRenderer) {
        self.page = page
        self.renderer = renderer
        super.init(frame: .zero)
        let tiled = layer as! CATiledLayer
        tiled.levelsOfDetail = 5
        tiled.levelsOfDetailBias = 3
        tiled.tileSize = CGSize(width: 512, height: 512)
        isOpaque = true
        backgroundColor = .white
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.clip(to: rect)
        renderer.drawBackground(page, in: ctx, rect: bounds)
    }
}

/// One page: shadow, tiled background, and interactive elements.
final class PageView: UIView {
    var page: PageSpec
    private var renderer: PageRenderer
    private let background: TiledBackgroundView
    private let elementsLayer = UIView()
    private weak var controller: NoteCanvasController?
    private var elementViews: [UUID: ElementView] = [:]

    var elementsInteractive = false {
        didSet {
            elementsLayer.isUserInteractionEnabled = elementsInteractive
            elementViews.values.forEach { $0.setInteractive(elementsInteractive, tool: controller?.model.tool ?? .draw) }
        }
    }

    init(page: PageSpec, renderer: PageRenderer, controller: NoteCanvasController) {
        self.page = page
        self.renderer = renderer
        self.controller = controller
        background = TiledBackgroundView(page: page, renderer: renderer)
        super.init(frame: CGRect(x: 0, y: 0, width: page.size.width, height: page.size.height))
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 3)
        layer.shadowPath = UIBezierPath(rect: bounds).cgPath
        background.frame = bounds
        background.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(background)
        elementsLayer.frame = bounds
        elementsLayer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        elementsLayer.clipsToBounds = true
        addSubview(elementsLayer)
        reloadElements()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(page: PageSpec, renderer: PageRenderer) {
        self.page = page
        self.renderer = renderer
        background.page = page
        background.renderer = renderer
        background.layer.contents = nil
        background.setNeedsDisplay()
        reloadElements()
    }

    func reloadElements() {
        let ids = Set(page.elements.map(\.id))
        for (id, view) in elementViews where !ids.contains(id) {
            view.removeFromSuperview()
            elementViews[id] = nil
        }
        for element in page.elements {
            if let existing = elementViews[element.id] {
                existing.element = element
                elementsLayer.bringSubviewToFront(existing)
                continue
            }
            let view = ElementView.make(for: element, pageID: page.id, renderer: renderer, controller: controller)
            elementViews[element.id] = view
            elementsLayer.addSubview(view)
        }
        elementViews.values.forEach { $0.setInteractive(elementsInteractive, tool: controller?.model.tool ?? .draw) }
    }

    func beginEditing(_ id: UUID) {
        (elementViews[id] as? TextElementView)?.beginEditing()
    }

    func updateContentScale(_ scale: CGFloat) {
        for view in elementViews.values { view.updateContentScale(scale) }
    }
}
