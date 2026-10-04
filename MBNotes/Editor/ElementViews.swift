import NoteEngine
import UIKit

/// A movable sticker, image, or text box on a page. Frames are in page points.
class ElementView: UIView, UIGestureRecognizerDelegate, UIContextMenuInteractionDelegate {
    var element: PageElement {
        didSet { applyGeometry(); elementDidChange() }
    }
    let pageID: UUID
    let renderer: PageRenderer
    weak var controller: NoteCanvasController?
    private var pan: UIPanGestureRecognizer!
    private var pinch: UIPinchGestureRecognizer!
    private var rotate: UIRotationGestureRecognizer!
    private var startFrame = Rect(x: 0, y: 0, width: 0, height: 0)
    private var startRotation = 0.0

    static func make(for element: PageElement, pageID: UUID, renderer: PageRenderer, controller: NoteCanvasController?) -> ElementView {
        switch element.kind {
        case .text: return TextElementView(element: element, pageID: pageID, renderer: renderer, controller: controller)
        case .sticker, .image: return ArtElementView(element: element, pageID: pageID, renderer: renderer, controller: controller)
        }
    }

    init(element: PageElement, pageID: UUID, renderer: PageRenderer, controller: NoteCanvasController?) {
        self.element = element
        self.pageID = pageID
        self.renderer = renderer
        self.controller = controller
        super.init(frame: .zero)
        pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        rotate = UIRotationGestureRecognizer(target: self, action: #selector(handleRotate(_:)))
        for gesture in [pan!, pinch!, rotate!] as [UIGestureRecognizer] {
            gesture.delegate = self
            addGestureRecognizer(gesture)
        }
        addInteraction(UIContextMenuInteraction(delegate: self))
        applyGeometry()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func applyGeometry() {
        transform = .identity
        bounds = CGRect(x: 0, y: 0, width: element.frame.width, height: element.frame.height)
        center = CGPoint(x: element.frame.x + element.frame.width / 2, y: element.frame.y + element.frame.height / 2)
        transform = CGAffineTransform(rotationAngle: element.rotation)
    }

    func elementDidChange() {}

    func setInteractive(_ interactive: Bool, tool: EditorTool) {
        isUserInteractionEnabled = interactive
        let arranging = tool == .arrange
        pan.isEnabled = arranging
        pinch.isEnabled = arranging
        rotate.isEnabled = arranging && element.kind != .text
        layer.borderWidth = arranging ? 1 : 0
        layer.borderColor = UIColor(red: 0.97, green: 0.42, blue: 0.63, alpha: 0.6).cgColor
    }

    func updateContentScale(_ scale: CGFloat) {
        func apply(_ view: UIView) {
            view.contentScaleFactor = scale
            view.layer.contentsScale = scale
            view.setNeedsDisplay()
            view.subviews.forEach(apply)
        }
        apply(self)
    }

    private func commit() {
        controller?.elementChanged(element, pageID: pageID)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began: startFrame = element.frame
        case .changed:
            let t = gesture.translation(in: superview)
            element.frame.x = startFrame.x + t.x
            element.frame.y = startFrame.y + t.y
        case .ended, .cancelled: commit()
        default: break
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began: startFrame = element.frame
        case .changed:
            let s = max(0.2, min(gesture.scale, 6))
            var frame = startFrame
            frame.width = max(24, startFrame.width * s)
            // Text boxes only grow wider; art keeps its aspect ratio.
            frame.height = element.kind == .text ? startFrame.height : max(24, startFrame.height * s)
            frame.x = startFrame.x + (startFrame.width - frame.width) / 2
            frame.y = startFrame.y + (startFrame.height - frame.height) / 2
            element.frame = frame
        case .ended, .cancelled: commit()
        default: break
        }
    }

    @objc private func handleRotate(_ gesture: UIRotationGestureRecognizer) {
        switch gesture.state {
        case .began: startRotation = element.rotation
        case .changed: element.rotation = startRotation + gesture.rotation
        case .ended, .cancelled: commit()
        default: break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other.view === self
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
            return UIMenu(children: [
                UIAction(title: "Duplicate", image: UIImage(systemName: "plus.square.on.square")) { _ in
                    self.controller?.elementDuplicated(self.element, pageID: self.pageID)
                },
                UIAction(title: "Bring to front", image: UIImage(systemName: "square.3.layers.3d.top.filled")) { _ in
                    self.superview?.bringSubviewToFront(self)
                },
                UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                    self.controller?.elementDeleted(self.element.id, pageID: self.pageID)
                },
            ])
        })
    }
}

/// Stickers and images, drawn by the engine so they match exports exactly.
final class ArtElementView: ElementView {
    override init(element: PageElement, pageID: UUID, renderer: PageRenderer, controller: NoteCanvasController?) {
        super.init(element: element, pageID: pageID, renderer: renderer, controller: controller)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func elementDidChange() { setNeedsDisplay() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        var local = element
        local.frame = Rect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        local.rotation = 0
        var page = PageSpec(size: PageSize(width: bounds.width, height: bounds.height), paper: PaperRef(template: .blankPaper))
        page.elements = [local]
        renderer.drawElements(page, in: ctx, rect: bounds)
    }
}

/// A typed text box that grows as you type.
final class TextElementView: ElementView, UITextViewDelegate {
    private let textView = UITextView()

    override init(element: PageElement, pageID: UUID, renderer: PageRenderer, controller: NoteCanvasController?) {
        super.init(element: element, pageID: pageID, renderer: renderer, controller: controller)
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.delegate = self
        textView.frame = bounds
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(textView)
        applyText()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func applyText() {
        guard let text = element.text else { return }
        if textView.text != text.string || textView.attributedText.length == 0 {
            textView.attributedText = PageRenderer.attributedString(for: text)
        }
        textView.typingAttributes = PageRenderer.attributedString(for: TextContent(string: " ", fontName: text.fontName, fontSize: text.fontSize, color: text.color, alignment: text.alignment))
            .attributes(at: 0, effectiveRange: nil)
    }

    override func setInteractive(_ interactive: Bool, tool: EditorTool) {
        super.setInteractive(interactive, tool: tool)
        textView.isEditable = tool == .text
        textView.isSelectable = tool == .text
        textView.isUserInteractionEnabled = tool == .text
    }

    func beginEditing() {
        DispatchQueue.main.async {
            self.textView.isEditable = true
            self.textView.isUserInteractionEnabled = true
            self.textView.becomeFirstResponder()
        }
    }

    func textViewDidChange(_ textView: UITextView) {
        var updated = element
        updated.text?.string = textView.text
        let fitting = textView.sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        updated.frame.height = max(34, fitting.height + 4)
        element = updated
        controller?.elementChanged(updated, pageID: pageID)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        if textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            controller?.elementDeleted(element.id, pageID: pageID)
        }
    }
}
