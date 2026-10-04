import NoteEngine
import NoteIntelligence
import PencilKit
import UIKit

/// The writing surface: one zoomable PencilKit canvas spanning every page.
///
/// Pages are laid out top to bottom in document coordinates (points at 100%
/// zoom). Page backgrounds and elements live in an underlay view inside the
/// canvas's scroll view, scaled to match the zoom, so ink always draws on top.
/// Ink is stored per page in page coordinates and stitched together here.
@MainActor
final class NoteCanvasController: UIViewController, PKCanvasViewDelegate, UIGestureRecognizerDelegate {
    static let pageGap: CGFloat = 28
    static let margin: CGFloat = 24

    let model: EditorModel
    let canvas = NoteCanvas()
    private let underlay = UIView()
    private let toolPicker = PKToolPicker()
    private var pageViews: [PageView] = []
    private(set) var pageFrames: [CGRect] = []
    private var documentSize: CGSize = .zero
    private var isApplyingDrawing = false
    private var didInitialZoom = false
    private var inkNotifyTask: Task<Void, Never>?
    private var renderedLayoutVersion = -1
    private var appliedTool: EditorTool?
    private lazy var textTap = UITapGestureRecognizer(target: self, action: #selector(handleTextTap(_:)))
    private lazy var replayTap = UITapGestureRecognizer(target: self, action: #selector(handleReplayTap(_:)))
    /// Non-nil while ink replays alongside a recording.
    private(set) var replayCutoff: Date?

    init(model: EditorModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.086, green: 0.082, blue: 0.122, alpha: 1) : UIColor(red: 0.95, green: 0.933, blue: 0.96, alpha: 1) }

        canvas.controller = self
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // Paper is always light, so ink keeps its true colors in dark mode.
        canvas.overrideUserInterfaceStyle = .light
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.maximumZoomScale = 5
        canvas.minimumZoomScale = 0.25
        canvas.bouncesZoom = true
        canvas.alwaysBounceVertical = true
        canvas.showsHorizontalScrollIndicator = false
        canvas.delegate = self
        canvas.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(canvas)
        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: view.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        canvas.insertSubview(underlay, at: 0)
        underlay.layer.anchorPoint = .zero

        textTap.delegate = self
        canvas.addGestureRecognizer(textTap)
        canvas.addGestureRecognizer(replayTap)
        replayTap.isEnabled = false

        toolPicker.colorUserInterfaceStyle = .light
        toolPicker.addObserver(canvas)
        canvas.tool = PKInkingTool(.pen, color: UIColor(red: 0.11, green: 0.106, blue: 0.18, alpha: 1), width: 3)

        rebuildPages()
        apply()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyTool(force: true)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard documentSize.width > 0, canvas.bounds.width > 0 else { return }
        let fit = canvas.bounds.width / documentSize.width
        canvas.minimumZoomScale = min(0.5, fit * 0.6)
        if !didInitialZoom {
            didInitialZoom = true
            canvas.setZoomScale(min(fit, 1.8), animated: false)
            canvas.contentOffset = CGPoint(x: -canvas.contentInset.left, y: -canvas.adjustedContentInset.top)
        }
        updateZoomLayout()
    }

    // MARK: Syncing with the model

    /// Applies model state that may have changed since the last SwiftUI update.
    func apply() {
        if renderedLayoutVersion != model.layoutVersion {
            rebuildPages()
        }
        canvas.drawingPolicy = model.fingerDrawing ? .anyInput : .pencilOnly
        if canvas.isShapeSnappingEnabled != model.shapeSnapping {
            ShapeSnapping.setEnabled(model.shapeSnapping, on: canvas)
        }
        applyTool()
    }

    private func applyTool(force: Bool = false) {
        let tool = replayCutoff == nil ? model.tool : .arrange
        guard force || appliedTool != tool else { return }
        appliedTool = tool
        let drawing = tool == .draw
        canvas.drawingGestureRecognizer.isEnabled = drawing
        textTap.isEnabled = tool == .text
        replayTap.isEnabled = replayCutoff != nil
        toolPicker.setVisible(drawing, forFirstResponder: canvas)
        if drawing {
            canvas.becomeFirstResponder()
        } else {
            view.endEditing(true)
        }
        for page in pageViews {
            page.elementsInteractive = tool != .draw && replayCutoff == nil
        }
    }

    /// Rebuilds page views and the stitched drawing after pages change.
    private func rebuildPages() {
        renderedLayoutVersion = model.layoutVersion
        let pages = model.manifest.pages
        let width = (pages.map(\.size.width).max() ?? 612) + Self.margin * 2
        var y = Self.margin
        pageFrames = pages.map { page in
            let frame = CGRect(x: (width - page.size.width) / 2, y: y, width: page.size.width, height: page.size.height)
            y += page.size.height + Self.pageGap
            return frame
        }
        documentSize = CGSize(width: width, height: y - Self.pageGap + Self.margin)

        pageViews.forEach { $0.removeFromSuperview() }
        let renderer = model.renderer
        pageViews = pages.enumerated().map { index, page in
            let view = PageView(page: page, renderer: renderer, controller: self)
            view.frame = pageFrames[index]
            underlay.addSubview(view)
            return view
        }
        underlay.bounds = CGRect(origin: .zero, size: documentSize)
        setDrawing(composedDrawing())
        updateZoomLayout()
        appliedTool = nil
        applyTool()
    }

    func reloadElements(page index: Int) {
        guard let view = pageViews[safe: index], let page = model.manifest.pages[safe: index] else { return }
        view.page = page
        view.reloadElements()
        view.elementsInteractive = model.tool != .draw
    }

    /// Re-renders backgrounds, for example after a paper change on the same layout.
    func refreshBackgrounds() {
        let renderer = model.renderer
        for (index, view) in pageViews.enumerated() {
            guard let page = model.manifest.pages[safe: index] else { continue }
            view.update(page: page, renderer: renderer)
        }
    }

    // MARK: Ink

    private func setDrawing(_ drawing: PKDrawing) {
        isApplyingDrawing = true
        canvas.drawing = drawing
        isApplyingDrawing = false
    }

    private func composedDrawing() -> PKDrawing {
        var strokes: [PKStroke] = []
        for (index, page) in model.manifest.pages.enumerated() {
            guard let origin = pageFrames[safe: index]?.origin else { continue }
            let offset = CGAffineTransform(translationX: origin.x, y: origin.y)
            for var stroke in model.drawing(for: page.id).strokes {
                stroke.transform = stroke.transform.concatenating(offset)
                strokes.append(stroke)
            }
        }
        return PKDrawing(strokes: strokes)
    }

    /// Splits the canvas drawing into page-relative drawings.
    private func splitDrawing(_ drawing: PKDrawing) -> [UUID: PKDrawing] {
        let pages = model.manifest.pages
        var buckets = [[PKStroke]](repeating: [], count: pages.count)
        for stroke in drawing.strokes {
            let midY = stroke.renderBounds.midY
            let index = pageFrames.firstIndex { midY >= $0.minY - Self.pageGap / 2 && midY < $0.maxY + Self.pageGap / 2 }
                ?? (midY < (pageFrames.first?.minY ?? 0) ? 0 : pages.count - 1)
            guard pages.indices.contains(index) else { continue }
            var local = stroke
            local.transform = stroke.transform.concatenating(CGAffineTransform(translationX: -pageFrames[index].minX, y: -pageFrames[index].minY))
            buckets[index].append(local)
        }
        var result: [UUID: PKDrawing] = [:]
        for (index, page) in pages.enumerated() where !buckets[index].isEmpty {
            result[page.id] = PKDrawing(strokes: buckets[index])
        }
        return result
    }

    /// Pushes the canvas's ink into the model. Called before page changes and saves.
    func flushInk(notify: Bool = true) {
        guard replayCutoff == nil, renderedLayoutVersion == model.layoutVersion else { return }
        inkNotifyTask?.cancel()
        let pages = splitDrawing(canvas.drawing)
        if notify { model.inkChanged(pages) } else { model.replaceInk(pages) }
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isApplyingDrawing, replayCutoff == nil else { return }
        inkNotifyTask?.cancel()
        inkNotifyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.flushInk()
        }
    }

    func undo() { canvas.undoManager?.undo() }
    func redo() { canvas.undoManager?.redo() }
    var canUndo: Bool { canvas.undoManager?.canUndo ?? false }

    // MARK: Zoom and scrolling

    private func updateZoomLayout() {
        let zoom = canvas.zoomScale
        underlay.transform = CGAffineTransform(scaleX: zoom, y: zoom)
        underlay.layer.position = .zero
        canvas.contentSize = CGSize(width: documentSize.width * zoom, height: documentSize.height * zoom)
        let horizontal = max(0, (canvas.bounds.width - documentSize.width * zoom) / 2)
        let chrome: CGFloat = traitCollection.horizontalSizeClass == .compact ? 116 : 64
        canvas.contentInset = UIEdgeInsets(top: view.safeAreaInsets.top + chrome, left: horizontal, bottom: view.safeAreaInsets.bottom + 120, right: horizontal)
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateZoomLayout()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        let contentScale = scale * (self.view.window?.screen.scale ?? 2)
        for page in pageViews { page.updateContentScale(contentScale) }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let centerY = (canvas.contentOffset.y + canvas.bounds.height / 2) / canvas.zoomScale
        if let index = pageFrames.firstIndex(where: { centerY < $0.maxY + Self.pageGap / 2 }), index != model.currentPageIndex {
            model.currentPageIndex = index
        }
    }

    func scroll(toPage index: Int, animated: Bool = true) {
        guard let frame = pageFrames[safe: index] else { return }
        view.layoutIfNeeded()
        let y = frame.minY * canvas.zoomScale - canvas.contentInset.top + 8
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: max(-canvas.contentInset.top, y)), animated: animated)
    }

    /// The center of the visible part of a page, in page coordinates.
    func visibleCenter(onPage index: Int) -> CGPoint? {
        guard let frame = pageFrames[safe: index] else { return nil }
        let zoom = canvas.zoomScale
        let visible = CGRect(x: canvas.contentOffset.x / zoom, y: canvas.contentOffset.y / zoom, width: canvas.bounds.width / zoom, height: canvas.bounds.height / zoom)
        let overlap = visible.intersection(frame)
        let center = overlap.isNull ? CGPoint(x: frame.midX, y: frame.midY) : CGPoint(x: overlap.midX, y: overlap.midY)
        return CGPoint(x: center.x - frame.minX, y: center.y - frame.minY)
    }

    /// Converts a canvas point to a page index and page coordinates.
    func pageLocation(of point: CGPoint) -> (index: Int, point: CGPoint)? {
        let doc = CGPoint(x: point.x / canvas.zoomScale, y: point.y / canvas.zoomScale)
        guard let index = pageFrames.firstIndex(where: { $0.contains(doc) }) else { return nil }
        return (index, CGPoint(x: doc.x - pageFrames[index].minX, y: doc.y - pageFrames[index].minY))
    }

    // MARK: Elements

    /// Lets taps reach element views underneath PencilKit's views when not drawing.
    func elementHit(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard model.tool != .draw, replayCutoff == nil else { return nil }
        let local = underlay.convert(point, from: canvas)
        guard let hit = underlay.hitTest(local, with: event) else { return nil }
        var view: UIView? = hit
        while let current = view {
            if current is ElementView { return hit }
            if current === underlay { return nil }
            view = current.superview
        }
        return nil
    }

    @objc private func handleTextTap(_ gesture: UITapGestureRecognizer) {
        guard let location = pageLocation(of: gesture.location(in: canvas)) else { return }
        guard let page = model.manifest.pages[safe: location.index] else { return }
        let width = min(340, page.size.width - location.point.x - 24)
        guard width > 60 else { return }
        let element = PageElement.text("", frame: Rect(x: location.point.x, y: location.point.y - 14, width: width, height: 34), style: TextContent(fontSize: 17, color: "#1C1B2E"))
        model.addElement(element, toPage: location.index)
        pageViews[safe: location.index]?.beginEditing(element.id)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // A tap on an existing text box edits it rather than creating a new one.
        !(touch.view is ElementView || touch.view?.superview is ElementView || touch.view is UITextView)
    }

    func elementChanged(_ element: PageElement, pageID: UUID) {
        model.updateElement(element, onPage: pageID)
    }

    func elementDeleted(_ id: UUID, pageID: UUID) {
        model.removeElement(id, onPage: pageID)
    }

    func elementDuplicated(_ element: PageElement, pageID: UUID) {
        guard let index = model.manifest.pages.firstIndex(where: { $0.id == pageID }) else { return }
        var copy = element
        copy.id = UUID()
        copy.frame.x += 20
        copy.frame.y += 20
        model.addElement(copy, toPage: index)
    }

    // MARK: Ink replay

    /// Fades ink written after `date` so you can see what you wrote as the recording plays.
    func showReplay(until date: Date?, recordingStart: Date, recordingEnd: Date) {
        if date == nil {
            guard replayCutoff != nil else { return }
            replayCutoff = nil
            setDrawing(composedDrawing())
            applyTool(force: true)
            return
        }
        if replayCutoff == nil { flushInk(notify: false) }
        replayCutoff = date
        applyTool(force: true)
        let composed = composedDrawing()
        let strokes = composed.strokes.map { stroke -> PKStroke in
            let created = stroke.path.creationDate
            guard created >= recordingStart, created <= recordingEnd.addingTimeInterval(5), created > date! else { return stroke }
            let ink = PKInk(stroke.ink.inkType, color: stroke.ink.color.withAlphaComponent(0.14))
            return PKStroke(ink: ink, path: stroke.path, transform: stroke.transform, mask: stroke.mask)
        }
        setDrawing(PKDrawing(strokes: strokes))
    }

    @objc private func handleReplayTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: canvas)
        let doc = CGPoint(x: point.x / canvas.zoomScale, y: point.y / canvas.zoomScale)
        let candidates = canvas.drawing.strokes.filter { $0.renderBounds.insetBy(dx: -12, dy: -12).contains(doc) }
        guard let stroke = candidates.max(by: { $0.path.creationDate < $1.path.creationDate }) else { return }
        model.recording.seek(toStrokeDate: stroke.path.creationDate)
    }
}

/// PencilKit canvas that lets taps through to page elements outside draw mode.
final class NoteCanvas: PKCanvasView {
    weak var controller: NoteCanvasController?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let hit = controller?.elementHit(point, with: event) { return hit }
        return super.hitTest(point, with: event)
    }
}
