import NoteEngine
import NoteIntelligence
import PencilKit
import UIKit
import UniformTypeIdentifiers

/// The writing surface: one zoomable PencilKit canvas spanning every page.
///
/// Pages are laid out by `PageLayout` in document coordinates (points at 100% zoom),
/// side by side or top to bottom. Page backgrounds and elements live in an underlay view
/// inside the canvas's scroll view, scaled to match the zoom, so ink always draws on top.
/// Ink is stored per page in page coordinates and stitched together here.
@MainActor
final class NoteCanvasController: UIViewController, PKCanvasViewDelegate, PKToolPickerObserver, UIGestureRecognizerDelegate, UIPencilInteractionDelegate, UIDropInteractionDelegate {
    let model: EditorModel
    let canvas = NoteCanvas()
    private let underlay = UIView()
    private let toolPicker = PKToolPicker()
    private var pageViews: [PageView] = []
    private(set) var layout = PageLayout(sizes: [], axis: .vertical)
    private var isApplyingDrawing = false
    private var didInitialZoom = false
    private var inkNotifyTask: Task<Void, Never>?
    private var renderedLayoutVersion = -1
    private var renderedAxis: PageLayout.Axis?
    private var appliedMode: EditorMode?
    private var pickerObscuredHeight: CGFloat = 0
    private var keyboardOverlap: CGFloat = 0
    private var lastStrokeCount = 0
    private var convertPending: [PKStroke] = []
    private var convertTask: Task<Void, Never>?
    private var lastBeautified: (key: EditorModel.StrokeKey, shape: StrokeBeautifier.Shape, date: Date)?
    private var repeatTimer: Timer?
    private weak var editingText: TextElementView?
    private lazy var textTap = UITapGestureRecognizer(target: self, action: #selector(handleTextTap(_:)))
    private lazy var replayTap = UITapGestureRecognizer(target: self, action: #selector(handleReplayTap(_:)))
    private lazy var deselectTap = UITapGestureRecognizer(target: self, action: #selector(handleDeselectTap(_:)))
    private lazy var undoTap = UITapGestureRecognizer(target: self, action: #selector(handleUndoTap))
    private lazy var redoTap = UITapGestureRecognizer(target: self, action: #selector(handleRedoTap))
    private lazy var undoHold = UILongPressGestureRecognizer(target: self, action: #selector(handleUndoHold(_:)))
    private lazy var redoHold = UILongPressGestureRecognizer(target: self, action: #selector(handleRedoHold(_:)))
    private lazy var zoomTap = UITapGestureRecognizer(target: self, action: #selector(handleZoomTap(_:)))
    /// Non-nil while ink replays alongside a recording.
    private(set) var replayCutoff: Date?
    private var replayRecording: RecordingSummary?

    init(model: EditorModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// iPadOS's own three-finger undo gestures would fight the tap gestures here.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(AppTheme.current.canvasBackdrop)

        canvas.controller = self
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // Paper is always light, so ink keeps its true colors in dark mode.
        canvas.overrideUserInterfaceStyle = .light
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.maximumZoomScale = 5
        canvas.minimumZoomScale = 0.25
        canvas.bouncesZoom = true
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

        installGestures()
        canvas.addInteraction(UIPencilInteraction(delegate: self))
        canvas.addInteraction(UIDropInteraction(delegate: self))

        toolPicker.colorUserInterfaceStyle = .light
        toolPicker.addObserver(canvas)
        toolPicker.addObserver(self)
        canvas.tool = PKInkingTool(.pen, color: UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1), width: 3)

        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)

        rebuildPages()
        apply()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyMode(force: true)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard layout.documentSize.width > 0, canvas.bounds.width > 0 else { return }
        canvas.minimumZoomScale = min(0.5, fitZoom * 0.6)
        if !didInitialZoom {
            didInitialZoom = true
            canvas.setZoomScale(min(fitZoom, 1.8), animated: false)
            scroll(toPage: model.currentPageIndex, animated: false)
        }
        updateZoomLayout()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        let page = model.currentPageIndex
        coordinator.animate(alongsideTransition: nil) { _ in
            self.canvas.setZoomScale(min(self.fitZoom, 1.8), animated: false)
            self.scroll(toPage: page, animated: false)
        }
    }

    // MARK: Syncing with the model

    /// Applies model state that may have changed since the last SwiftUI update.
    func apply() {
        if renderedLayoutVersion != model.layoutVersion || renderedAxis != model.pageAxis {
            rebuildPages()
        }
        canvas.drawingPolicy = model.fingerDrawing ? .anyInput : .pencilOnly
        zoomTap.isEnabled = model.mode != .pen || !model.fingerDrawing
        applyMode()
        if let target = model.pendingScroll {
            model.pendingScroll = nil
            view.layoutIfNeeded()
            scroll(toPage: target)
        }
        if !model.convertMode { convertPending = []; convertTask?.cancel() }
        syncSelection()
    }

    private func applyMode(force: Bool = false) {
        let mode = replayCutoff == nil ? model.mode : .view
        guard force || appliedMode != mode else { return }
        appliedMode = mode
        let drawing = mode == .pen
        canvas.drawingGestureRecognizer.isEnabled = drawing
        textTap.isEnabled = mode == .text
        deselectTap.isEnabled = mode == .select
        replayTap.isEnabled = replayCutoff != nil
        toolPicker.setVisible(drawing, forFirstResponder: canvas)
        if drawing {
            canvas.becomeFirstResponder()
        } else {
            view.endEditing(true)
        }
        for page in pageViews {
            page.setMode(mode, interactive: (mode == .text || mode == .select) && replayCutoff == nil)
        }
        lastStrokeCount = canvas.drawing.strokes.count
    }

    /// Re-asserts the tool picker after a sheet or text field took first responder.
    func restoreFirstResponder() {
        guard appliedMode == .pen, replayCutoff == nil else { return }
        canvas.becomeFirstResponder()
        toolPicker.setVisible(true, forFirstResponder: canvas)
    }

    /// Rebuilds page views and the stitched drawing after pages change.
    private func rebuildPages() {
        renderedLayoutVersion = model.layoutVersion
        renderedAxis = model.pageAxis
        let pages = model.manifest.pages
        layout = PageLayout(sizes: pages.map(\.size), axis: model.pageAxis)
        canvas.alwaysBounceVertical = layout.axis == .vertical
        canvas.alwaysBounceHorizontal = layout.axis == .horizontal
        canvas.decelerationRate = layout.axis == .horizontal ? .fast : .normal

        pageViews.forEach { $0.removeFromSuperview() }
        let renderer = model.renderer
        pageViews = pages.enumerated().map { index, page in
            let view = PageView(page: page, renderer: renderer, controller: self)
            view.frame = layout.frames[index]
            underlay.addSubview(view)
            return view
        }
        underlay.bounds = CGRect(origin: .zero, size: layout.documentSize)
        setDrawing(composedDrawing())
        updateZoomLayout()
        appliedMode = nil
        applyMode()
    }

    func reloadElements(page index: Int) {
        guard let view = pageViews[safe: index], let page = model.manifest.pages[safe: index] else { return }
        view.page = page
        view.reloadElements()
        syncSelection()
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
        lastStrokeCount = drawing.strokes.count
    }

    private func composedDrawing() -> PKDrawing {
        var strokes: [PKStroke] = []
        for (index, page) in model.manifest.pages.enumerated() {
            guard let origin = layout.frames[safe: index]?.origin else { continue }
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
            guard let index = layout.pageIndex(forStrokeBounds: stroke.renderBounds), pages.indices.contains(index) else { continue }
            var local = stroke
            let frame = layout.frames[index]
            local.transform = stroke.transform.concatenating(CGAffineTransform(translationX: -frame.minX, y: -frame.minY))
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
        let strokes = canvasView.drawing.strokes
        if strokes.count == lastStrokeCount + 1, let newest = strokes.last {
            lastStrokeCount = strokes.count
            if model.convertMode {
                queueForConversion(newest)
            } else if model.shapeSnapping {
                beautifyIfHeld(newest)
            }
        } else {
            lastStrokeCount = strokes.count
        }
        inkNotifyTask?.cancel()
        inkNotifyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.flushInk()
        }
    }

    // MARK: Shape snapping

    /// Replaces a stroke whose pen was held still at the end with the clean shape it was
    /// drawn as. Holding is the signal, as in Notes and Freeform, so handwriting is untouched.
    private func beautifyIfHeld(_ stroke: PKStroke) {
        let path = stroke.path
        guard path.count > 8, let last = path.last else { return }
        var i = path.count - 1
        while i > 0, hypot(path[i - 1].location.x - last.location.x, path[i - 1].location.y - last.location.y) < 6 { i -= 1 }
        let heldFor = last.timeOffset - path[i].timeOffset
        let points = (0..<path.count).map { path[$0].location.applying(stroke.transform) }

        // A short caret drawn right after a line turns it into an arrow, held or not.
        if let previous = lastBeautified, Date().timeIntervalSince(previous.date) < 2,
           let merged = StrokeBeautifier.mergeArrowhead(previous: previous.shape, caret: points),
           let previousIndex = canvas.drawing.strokes.firstIndex(where: { EditorModel.StrokeKey($0) == previous.key }) {
            var strokes = canvas.drawing.strokes
            let ink = strokes[previousIndex].ink
            let width = strokes[previousIndex].path.first?.size.width ?? 3
            strokes.removeLast()
            strokes.remove(at: previousIndex)
            strokes += Self.strokes(for: merged, ink: ink, width: width)
            replaceDrawing(PKDrawing(strokes: strokes), actionName: "Arrow")
            lastBeautified = nil
            return
        }
        guard heldFor >= 0.35, let shape = StrokeBeautifier.fit(points) else {
            lastBeautified = nil
            return
        }
        var strokes = canvas.drawing.strokes
        strokes.removeLast()
        let replacement = Self.strokes(for: shape, ink: stroke.ink, width: path.first?.size.width ?? 3)
        strokes += replacement
        replaceDrawing(PKDrawing(strokes: strokes), actionName: "Snap Shape")
        if case .line = shape, let key = replacement.first.map(EditorModel.StrokeKey.init) {
            lastBeautified = (key, shape, Date())
        } else {
            lastBeautified = nil
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Sets the drawing programmatically with an undo step, so the raw stroke comes back on undo.
    private func replaceDrawing(_ drawing: PKDrawing, actionName: String) {
        let previous = canvas.drawing
        setDrawing(drawing)
        model.undoManager.registerUndo(withTarget: self) { controller in
            let current = controller.canvas.drawing
            controller.setDrawing(previous)
            controller.model.undoManager.registerUndo(withTarget: controller) { again in
                again.replaceDrawing(current, actionName: actionName)
            }
            controller.flushInk()
        }
        model.undoManager.setActionName(actionName)
        flushInk()
    }

    /// Builds PencilKit strokes for a fitted shape with the original ink.
    static func strokes(for shape: StrokeBeautifier.Shape, ink: PKInk, width: CGFloat) -> [PKStroke] {
        func stroke(_ points: [CGPoint]) -> PKStroke {
            let controlPoints = points.enumerated().map { index, point in
                PKStrokePoint(location: point, timeOffset: Double(index) * 0.01, size: CGSize(width: width, height: width), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: ink, path: PKStrokePath(controlPoints: controlPoints, creationDate: Date()))
        }
        return [stroke(shape.outline)] + shape.arrowhead.map(stroke)
    }

    // MARK: Convert handwriting

    private func queueForConversion(_ stroke: PKStroke) {
        convertPending.append(stroke)
        convertTask?.cancel()
        convertTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            let pending = self.convertPending
            self.convertPending = []
            self.flushInk()
            // All pending strokes belong to the page the first one landed on.
            guard let first = pending.first, let index = self.layout.pageIndex(forStrokeBounds: first.renderBounds),
                  let page = self.model.manifest.pages[safe: index] else { return }
            let frame = self.layout.frames[index]
            let local = pending.map { stroke -> PKStroke in
                var s = stroke
                s.transform = stroke.transform.concatenating(CGAffineTransform(translationX: -frame.minX, y: -frame.minY))
                return s
            }
            await self.model.convertStrokes(local, onPage: page.id)
        }
    }

    // MARK: Undo and gestures

    private func installGestures() {
        textTap.delegate = self
        canvas.addGestureRecognizer(textTap)
        canvas.addGestureRecognizer(replayTap)
        replayTap.isEnabled = false
        deselectTap.delegate = self
        canvas.addGestureRecognizer(deselectTap)

        undoTap.numberOfTouchesRequired = 2
        redoTap.numberOfTouchesRequired = 3
        undoHold.numberOfTouchesRequired = 2
        redoHold.numberOfTouchesRequired = 3
        undoHold.minimumPressDuration = 0.45
        redoHold.minimumPressDuration = 0.45
        zoomTap.numberOfTapsRequired = 2
        for gesture in [undoTap, redoTap, undoHold, redoHold, zoomTap] {
            gesture.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
            gesture.delegate = self
            canvas.addGestureRecognizer(gesture)
        }
        undoTap.require(toFail: redoTap)
        undoTap.require(toFail: undoHold)
        redoTap.require(toFail: redoHold)
        updateGestureSettings()
    }

    func updateGestureSettings() {
        let enabled = UserDefaults.standard.object(forKey: "tapUndoGestures") as? Bool ?? true
        for gesture in [undoTap, redoTap, undoHold, redoHold] { gesture.isEnabled = enabled }
    }

    @objc private func handleUndoTap() {
        dropAccidentalDot()
        model.undo()
    }

    @objc private func handleRedoTap() {
        dropAccidentalDot()
        model.redo()
    }

    @objc private func handleUndoHold(_ gesture: UILongPressGestureRecognizer) {
        handleHold(gesture) { [weak self] in self?.model.undo() }
    }

    @objc private func handleRedoHold(_ gesture: UILongPressGestureRecognizer) {
        handleHold(gesture) { [weak self] in self?.model.redo() }
    }

    /// Holding repeats undo or redo, speeding up the longer it is held.
    private func handleHold(_ gesture: UILongPressGestureRecognizer, _ action: @escaping () -> Void) {
        switch gesture.state {
        case .began:
            dropAccidentalDot()
            action()
            var interval = 0.4
            let generator = UISelectionFeedbackGenerator()
            func schedule() {
                repeatTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        guard self?.repeatTimer != nil else { return }
                        action()
                        generator.selectionChanged()
                        interval = max(0.08, interval * 0.8)
                        schedule()
                    }
                }
            }
            schedule()
        case .ended, .cancelled, .failed:
            repeatTimer?.invalidate()
            repeatTimer = nil
        default:
            break
        }
    }

    /// The first finger of a multi-finger tap can leave a tiny stroke when finger drawing is on.
    private func dropAccidentalDot() {
        guard model.fingerDrawing, let last = canvas.drawing.strokes.last else { return }
        let bounds = last.renderBounds
        let age = Date().timeIntervalSince(last.path.creationDate)
        if bounds.width < 4, bounds.height < 4, age < 0.3 {
            var strokes = canvas.drawing.strokes
            strokes.removeLast()
            setDrawing(PKDrawing(strokes: strokes))
            if model.undoManager.canUndo { model.undoManager.undo() }
        }
    }

    @objc private func handleZoomTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: canvas)
        if abs(canvas.zoomScale - fitZoom) < fitZoom * 0.08 {
            let target = min(canvas.maximumZoomScale, fitZoom * 2)
            let size = CGSize(width: canvas.bounds.width / target, height: canvas.bounds.height / target)
            let origin = CGPoint(x: point.x / canvas.zoomScale - size.width / 2, y: point.y / canvas.zoomScale - size.height / 2)
            canvas.zoom(to: CGRect(origin: origin, size: size), animated: true)
        } else {
            zoomToFit(animated: true)
        }
    }

    func zoomToFit(animated: Bool) {
        let page = model.currentPageIndex
        canvas.setZoomScale(fitZoom, animated: animated)
        scroll(toPage: page, animated: animated)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === textTap || gestureRecognizer === deselectTap {
            // A tap on an existing element edits or selects it rather than placing or clearing.
            return !(touch.view is ElementView || touch.view?.superview is ElementView || touch.view is UITextView)
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Multi-finger taps must not block scrolling or PencilKit's own gestures.
        true
    }

    // MARK: Apple Pencil

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        guard !toolPicker.isVisible else { return }
        switch UIPencilInteraction.preferredTapAction {
        case .switchEraser:
            canvas.tool = canvas.tool is PKEraserTool ? PKInkingTool(.pen, color: .black, width: 3) : PKEraserTool(.bitmap)
        case .switchPrevious, .showColorPalette, .showInkAttributes:
            model.mode = .pen
        default:
            break
        }
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended, !toolPicker.isVisible else { return }
        model.mode = .pen
    }

    // MARK: Tool picker and keyboard insets

    nonisolated func toolPickerFramesObscuredDidChange(_ toolPicker: PKToolPicker) {
        Task { @MainActor in
            self.pickerObscuredHeight = toolPicker.frameObscured(in: self.view).height
            self.updateZoomLayout()
        }
    }

    nonisolated func toolPickerVisibilityDidChange(_ toolPicker: PKToolPicker) {
        Task { @MainActor in
            self.pickerObscuredHeight = toolPicker.isVisible ? toolPicker.frameObscured(in: self.view).height : 0
            self.updateZoomLayout()
        }
    }

    @objc private func keyboardWillChange(_ note: Notification) {
        guard let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue, let window = view.window else { return }
        let inView = view.convert(frame, from: window)
        let overlap = note.name == UIResponder.keyboardWillHideNotification ? 0 : max(0, view.bounds.maxY - inView.minY)
        keyboardOverlap = overlap
        updateZoomLayout()
    }

    // MARK: Zoom and scrolling

    /// Side by side fits the whole page; continuous fits the width.
    var fitZoom: CGFloat {
        guard layout.documentSize.width > 0, canvas.bounds.width > 0 else { return 1 }
        let frame = layout.frames[safe: model.currentPageIndex] ?? layout.frames.first ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        let safe = view.safeAreaInsets
        let availableWidth = canvas.bounds.width - 16
        let availableHeight = canvas.bounds.height - safe.top - max(safe.bottom, pickerObscuredHeight) - 16
        switch layout.axis {
        case .vertical: return availableWidth / layout.documentSize.width
        case .horizontal: return min(availableWidth / frame.width, availableHeight / frame.height)
        }
    }

    private func updateZoomLayout() {
        let zoom = canvas.zoomScale
        underlay.transform = CGAffineTransform(scaleX: zoom, y: zoom)
        underlay.layer.position = .zero
        canvas.contentSize = CGSize(width: layout.documentSize.width * zoom, height: layout.documentSize.height * zoom)
        let safe = view.safeAreaInsets
        let horizontal = max(0, (canvas.bounds.width - layout.documentSize.width * zoom) / 2)
        let bottom = max(safe.bottom, pickerObscuredHeight, keyboardOverlap)
        let vertical = layout.axis == .horizontal ? max(0, (canvas.bounds.height - safe.top - bottom - layout.documentSize.height * zoom) / 2) : 0
        canvas.contentInset = UIEdgeInsets(top: safe.top + vertical, left: horizontal, bottom: bottom + vertical, right: horizontal)
        canvas.scrollIndicatorInsets = UIEdgeInsets(top: safe.top, left: 0, bottom: bottom, right: 0)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateZoomLayout()
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateZoomLayout()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        let contentScale = scale * (self.view.window?.screen.scale ?? 2)
        for page in pageViews { page.updateContentScale(contentScale) }
        // Settling near fit snaps to fit.
        if abs(scale - fitZoom) < fitZoom * 0.08, scale != fitZoom {
            canvas.setZoomScale(fitZoom, animated: true)
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let zoom = canvas.zoomScale
        let viewport = CGRect(x: canvas.contentOffset.x / zoom, y: canvas.contentOffset.y / zoom, width: canvas.bounds.width / zoom, height: canvas.bounds.height / zoom)
        if let index = layout.visiblePage(in: viewport), index != model.currentPageIndex {
            model.currentPageIndex = index
        }
    }

    /// In side-by-side mode, flicks land on a page boundary when a page fits the viewport.
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard layout.axis == .horizontal, !layout.frames.isEmpty else { return }
        let zoom = canvas.zoomScale
        let pageWidth = (layout.frames[safe: model.currentPageIndex]?.width ?? 612) * zoom
        let viewportWidth = canvas.bounds.width - canvas.contentInset.left - canvas.contentInset.right
        guard pageWidth <= viewportWidth + 1 else { return }
        var index = model.currentPageIndex
        if velocity.x > 0.3 { index += 1 } else if velocity.x < -0.3 { index -= 1 }
        index = max(0, min(layout.frames.count - 1, index))
        let offset = layout.offset(centering: index, viewportLength: viewportWidth, zoom: zoom) - canvas.contentInset.left
        targetContentOffset.pointee = CGPoint(x: offset, y: targetContentOffset.pointee.y)
    }

    func scroll(toPage index: Int, animated: Bool = true) {
        guard let frame = layout.frames[safe: index] else { return }
        view.layoutIfNeeded()
        let zoom = canvas.zoomScale
        switch layout.axis {
        case .vertical:
            let y = frame.minY * zoom - canvas.contentInset.top + 8
            canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: max(-canvas.contentInset.top, y)), animated: animated)
        case .horizontal:
            let viewportWidth = canvas.bounds.width - canvas.contentInset.left - canvas.contentInset.right
            let x = layout.offset(centering: index, viewportLength: viewportWidth, zoom: zoom) - canvas.contentInset.left
            canvas.setContentOffset(CGPoint(x: x, y: canvas.contentOffset.y), animated: animated)
        }
        if model.currentPageIndex != index { model.currentPageIndex = index }
    }

    /// Scrolls so a rect on a page (page coordinates) is visible, used for the text caret.
    func scrollToVisible(rect: CGRect, onPage pageID: UUID) {
        guard let index = model.manifest.pages.firstIndex(where: { $0.id == pageID }), let frame = layout.frames[safe: index] else { return }
        let zoom = canvas.zoomScale
        let doc = rect.offsetBy(dx: frame.minX, dy: frame.minY)
        let target = CGRect(x: doc.minX * zoom, y: doc.minY * zoom, width: doc.width * zoom, height: doc.height * zoom).insetBy(dx: -40, dy: -60)
        canvas.scrollRectToVisible(target, animated: true)
    }

    /// The center of the visible part of a page, in page coordinates.
    func visibleCenter(onPage index: Int) -> CGPoint? {
        guard let frame = layout.frames[safe: index] else { return nil }
        let zoom = canvas.zoomScale
        let visible = CGRect(x: canvas.contentOffset.x / zoom, y: canvas.contentOffset.y / zoom, width: canvas.bounds.width / zoom, height: canvas.bounds.height / zoom)
        let overlap = visible.intersection(frame)
        let center = overlap.isNull ? CGPoint(x: frame.midX, y: frame.midY) : CGPoint(x: overlap.midX, y: overlap.midY)
        return CGPoint(x: center.x - frame.minX, y: center.y - frame.minY)
    }

    /// Converts a canvas point to a page index and page coordinates.
    func pageLocation(of point: CGPoint) -> (index: Int, point: CGPoint)? {
        let doc = CGPoint(x: point.x / canvas.zoomScale, y: point.y / canvas.zoomScale)
        guard let index = layout.frames.firstIndex(where: { $0.contains(doc) }) else { return nil }
        return (index, CGPoint(x: doc.x - layout.frames[index].minX, y: doc.y - layout.frames[index].minY))
    }

    // MARK: Elements

    /// Lets taps reach element views underneath PencilKit's views when not drawing.
    func elementHit(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard model.mode == .text || model.mode == .select, replayCutoff == nil else { return nil }
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
        guard let id = model.addText(at: location.point, onPage: location.index) else { return }
        pageViews[safe: location.index]?.beginEditing(id)
    }

    @objc private func handleDeselectTap(_ gesture: UITapGestureRecognizer) {
        select(nil)
    }

    func select(_ view: ElementView?) {
        if let view {
            model.selection = ElementSelection(pageID: view.pageID, elementID: view.element.id)
        } else {
            model.selection = nil
        }
        syncSelection()
    }

    private func syncSelection() {
        for page in pageViews {
            for (id, view) in page.elementViews {
                view.isSelected = model.selection?.elementID == id && model.mode == .select
            }
        }
    }

    func elementChanged(_ element: PageElement, pageID: UUID, undoable: Bool = true) {
        model.updateElement(element, onPage: pageID, undoable: undoable)
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

    func applyTextStyle(color: String, to id: UUID, pageID: UUID) {
        model.applyTextStyle(color: color, to: id, onPage: pageID)
    }

    func textStyleChanged(_ text: TextContent) {
        model.rememberTextStyle(text)
    }

    func textEditingBegan(_ view: TextElementView) {
        editingText = view
    }

    func textEditingEnded() {
        editingText = nil
    }

    func endTextEditing() {
        view.endEditing(true)
    }

    /// Deletes the selected element, for the keyboard's Delete key.
    func deleteSelection() {
        guard let selection = model.selection else { return }
        model.removeElement(selection.elementID, onPage: selection.pageID)
    }

    // MARK: Paste and drop

    override var canBecomeFirstResponder: Bool { true }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            return UIPasteboard.general.hasImages || UIPasteboard.general.hasStrings
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let board = UIPasteboard.general
        if let image = board.image, let data = image.pngData() {
            model.addImage(data)
        } else if let string = board.string {
            let index = model.currentPageIndex
            let center = visibleCenter(onPage: index) ?? CGPoint(x: 100, y: 100)
            if let id = model.addText(at: CGPoint(x: max(24, center.x - 160), y: center.y), onPage: index),
               let page = model.manifest.pages[safe: index],
               var element = page.elements.first(where: { $0.id == id }) {
                element.text?.string = string
                model.updateElement(element, onPage: page.id, undoable: false)
            }
        }
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        session.hasItemsConforming(toTypeIdentifiers: [UTType.image.identifier, UTType.plainText.identifier])
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        for item in session.items {
            if item.itemProvider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                item.itemProvider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in self.model.addImage(data) }
                }
            } else if item.itemProvider.canLoadObject(ofClass: NSString.self) {
                _ = item.itemProvider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let string = object as? String else { return }
                    Task { @MainActor in
                        UIPasteboard.general.string = string
                        self.paste(nil)
                    }
                }
            }
        }
    }

    // MARK: Ink replay

    /// Fades ink written after `date` so you can see what you wrote as the recording plays.
    func showReplay(until date: Date?, recording: RecordingSummary?) {
        guard let date, let recording else {
            guard replayCutoff != nil else { return }
            replayCutoff = nil
            replayRecording = nil
            setDrawing(composedDrawing())
            applyMode(force: true)
            return
        }
        if replayCutoff == nil { flushInk(notify: false) }
        replayCutoff = date
        replayRecording = recording
        applyMode(force: true)
        let start = recording.startedAt
        let end = recording.wallClock(forAudioTime: recording.duration).addingTimeInterval(5)
        let composed = composedDrawing()
        let strokes = composed.strokes.map { stroke -> PKStroke in
            let created = stroke.path.creationDate
            guard created >= start, created <= end, created > date else { return stroke }
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

/// PencilKit canvas that shares the note's undo stack and lets taps through to page
/// elements outside pen mode.
final class NoteCanvas: PKCanvasView {
    weak var controller: NoteCanvasController?

    /// PencilKit and the tool picker's undo buttons register on whatever this returns, so
    /// returning the note's manager puts ink, text, and page changes on one stack.
    override var undoManager: UndoManager? { controller?.model.undoManager }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let hit = controller?.elementHit(point, with: event) { return hit }
        return super.hitTest(point, with: event)
    }
}
