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
    var isSelected = false {
        didSet { updateSelectionAppearance() }
    }
    private var pan: UIPanGestureRecognizer!
    private var pinch: UIPinchGestureRecognizer!
    private var rotate: UIRotationGestureRecognizer!
    private var tap: UITapGestureRecognizer!
    private var startFrame = Rect(x: 0, y: 0, width: 0, height: 0)
    private var startRotation = 0.0
    private var mode = EditorMode.view
    private let handles: [UIView] = (0..<4).map { _ in UIView() }

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
        tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        for gesture in [pan!, pinch!, rotate!, tap!] as [UIGestureRecognizer] {
            gesture.delegate = self
            addGestureRecognizer(gesture)
        }
        addInteraction(UIContextMenuInteraction(delegate: self))
        for handle in handles {
            handle.backgroundColor = .white
            handle.layer.cornerRadius = 5
            handle.layer.borderWidth = 1.5
            handle.layer.borderColor = tintColor.cgColor
            handle.isHidden = true
            handle.isUserInteractionEnabled = false
            addSubview(handle)
        }
        applyGeometry()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func applyGeometry() {
        transform = .identity
        bounds = CGRect(x: 0, y: 0, width: element.frame.width, height: element.frame.height)
        center = CGPoint(x: element.frame.x + element.frame.width / 2, y: element.frame.y + element.frame.height / 2)
        transform = CGAffineTransform(rotationAngle: element.rotation)
        layoutHandles()
    }

    private func layoutHandles() {
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: bounds.width, y: 0), CGPoint(x: bounds.width, y: bounds.height), CGPoint(x: 0, y: bounds.height)]
        for (handle, corner) in zip(handles, corners) {
            handle.bounds = CGRect(x: 0, y: 0, width: 10, height: 10)
            handle.center = corner
        }
    }

    func elementDidChange() {}

    func setInteractive(_ interactive: Bool, mode: EditorMode) {
        self.mode = mode
        isUserInteractionEnabled = interactive
        let selecting = mode == .select
        pan.isEnabled = selecting
        pinch.isEnabled = selecting
        rotate.isEnabled = selecting && element.kind != .text
        tap.isEnabled = selecting
        if !selecting { isSelected = false }
        updateSelectionAppearance()
    }

    private func updateSelectionAppearance() {
        layer.borderWidth = isSelected ? 1.5 : 0
        layer.borderColor = tintColor.withAlphaComponent(0.9).cgColor
        handles.forEach { $0.isHidden = !isSelected; $0.layer.borderColor = tintColor.cgColor }
        bringSubviewsToFront()
    }

    private func bringSubviewsToFront() {
        handles.forEach(bringSubviewToFront)
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        updateSelectionAppearance()
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

    @objc private func handleTap() {
        controller?.select(self)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            startFrame = element.frame
            controller?.select(self)
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
        other.view === self && gestureRecognizer !== tap && other !== tap
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard mode == .select || mode == .text else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
            var children: [UIMenuElement] = []
            if element.kind == .text, let text = element.text {
                children.append(Self.colorMenu(current: text.color) { [weak self] hex in
                    guard let self else { return }
                    self.controller?.applyTextStyle(color: hex, to: self.element.id, pageID: self.pageID)
                })
            }
            children += [
                UIAction(title: "Duplicate", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
                    guard let self else { return }
                    self.controller?.elementDuplicated(self.element, pageID: self.pageID)
                },
                UIMenu(title: "Arrange", image: UIImage(systemName: "square.3.layers.3d"), children: [
                    UIAction(title: "Bring to Front", image: UIImage(systemName: "square.3.layers.3d.top.filled")) { [weak self] _ in
                        guard let self else { return }
                        self.controller?.model.bringToFront(self.element.id, onPage: self.pageID)
                    },
                    UIAction(title: "Send to Back", image: UIImage(systemName: "square.3.layers.3d.bottom.filled")) { [weak self] _ in
                        guard let self else { return }
                        self.controller?.model.sendToBack(self.element.id, onPage: self.pageID)
                    },
                ]),
                UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    guard let self else { return }
                    self.controller?.elementDeleted(self.element.id, pageID: self.pageID)
                },
            ]
            return UIMenu(children: children)
        })
    }

    /// Text colors that read well on paper, as a palette menu.
    static let textColors: [(name: String, hex: String)] = [
        ("Black", "#1C1C1E"), ("Gray", "#636366"), ("Violet", "#6A45E0"), ("Blue", "#0A62C9"), ("Teal", "#00747F"),
        ("Green", "#2E7650"), ("Orange", "#B8471A"), ("Red", "#BE1E3D"), ("Pink", "#B5336D"), ("Brown", "#7F5537"),
    ]

    static func colorMenu(current: String, apply: @escaping (String) -> Void) -> UIMenu {
        let actions = textColors.map { entry in
            let swatch = UIImage(systemName: "circle.fill")?.withTintColor(UIColor(Color(hex: entry.hex)), renderingMode: .alwaysOriginal)
            let action = UIAction(title: entry.name, image: swatch, state: current.caseInsensitiveCompare(entry.hex) == .orderedSame ? .on : .off) { _ in apply(entry.hex) }
            return action
        }
        return UIMenu(title: "Color", image: UIImage(systemName: "paintpalette"), options: .displayAsPalette, children: actions)
    }
}

import SwiftUI

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

/// A typed text box that grows as you type, with a format strip above the keyboard.
final class TextElementView: ElementView, UITextViewDelegate {
    private let textView = UITextView()
    private lazy var formatStrip = TextFormatStrip { [weak self] change in self?.applyFormat(change) }

    override init(element: PageElement, pageID: UUID, renderer: PageRenderer, controller: NoteCanvasController?) {
        super.init(element: element, pageID: pageID, renderer: renderer, controller: controller)
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.delegate = self
        textView.frame = bounds
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textView.inputAccessoryView = formatStrip
        addSubview(textView)
        applyText()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func elementDidChange() {
        applyText()
    }

    private func applyText() {
        guard let text = element.text else { return }
        let attributes = PageRenderer.attributedString(for: TextContent(string: " ", fontName: text.fontName, fontSize: text.fontSize, color: text.color, alignment: text.alignment))
            .attributes(at: 0, effectiveRange: nil)
        if textView.text != text.string || textView.attributedText.length == 0 {
            textView.attributedText = PageRenderer.attributedString(for: text)
        } else {
            // Style changes re-attribute the existing text without disturbing the caret.
            let range = textView.selectedRange
            textView.attributedText = PageRenderer.attributedString(for: text)
            textView.selectedRange = range
        }
        textView.typingAttributes = attributes
        formatStrip.update(color: text.color, size: text.fontSize, alignment: text.alignment)
        fitHeight()
    }

    override func setInteractive(_ interactive: Bool, mode: EditorMode) {
        super.setInteractive(interactive, mode: mode)
        textView.isEditable = mode == .text
        textView.isSelectable = mode == .text
        textView.isUserInteractionEnabled = mode == .text
    }

    func beginEditing() {
        DispatchQueue.main.async {
            self.textView.isEditable = true
            self.textView.isUserInteractionEnabled = true
            self.textView.becomeFirstResponder()
        }
    }

    private func fitHeight() {
        let fitting = textView.sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        let height = max(34, fitting.height + 4)
        if abs(height - element.frame.height) > 0.5 {
            element.frame.height = height
        }
    }

    private func applyFormat(_ change: TextFormatStrip.Change) {
        guard var text = element.text else { return }
        switch change {
        case .color(let hex): text.color = hex
        case .size(let delta): text.fontSize = min(72, max(9, text.fontSize + delta))
        case .alignment(let alignment): text.alignment = alignment
        case .done: textView.resignFirstResponder(); return
        }
        var updated = element
        updated.text = text
        element = updated
        controller?.textStyleChanged(text)
        controller?.elementChanged(updated, pageID: pageID)
    }

    // MARK: UITextViewDelegate

    func textViewDidChange(_ textView: UITextView) {
        var updated = element
        updated.text?.string = textView.text
        let fitting = textView.sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        updated.frame.height = max(34, fitting.height + 4)
        element = updated
        controller?.elementChanged(updated, pageID: pageID, undoable: false)
        scrollCaretIntoView()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        scrollCaretIntoView()
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        controller?.textEditingBegan(self)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        if textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            controller?.elementDeleted(element.id, pageID: pageID)
        } else {
            controller?.elementChanged(element, pageID: pageID)
        }
        controller?.textEditingEnded()
    }

    private func scrollCaretIntoView() {
        guard let range = textView.selectedTextRange else { return }
        let caret = textView.caretRect(for: range.end)
        let inPage = convert(caret, to: superview)
        controller?.scrollToVisible(rect: inPage, onPage: pageID)
    }
}

/// Color, size, and alignment controls shown above the keyboard while typing.
final class TextFormatStrip: UIView {
    enum Change {
        case color(String)
        case size(Double)
        case alignment(String)
        case done
    }

    private let onChange: (Change) -> Void
    private var colorButtons: [UIButton] = []
    private let alignmentControl = UISegmentedControl(items: [
        UIImage(systemName: "text.alignleft")!, UIImage(systemName: "text.aligncenter")!, UIImage(systemName: "text.alignright")!,
    ])
    private let sizeLabel = UILabel()

    init(onChange: @escaping (Change) -> Void) {
        self.onChange = onChange
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 48))
        autoresizingMask = .flexibleWidth
        let background = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        background.frame = bounds
        background.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(background)

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])

        for entry in ElementView.textColors {
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: "circle.fill"), for: .normal)
            button.tintColor = UIColor(Color(hex: entry.hex))
            button.accessibilityLabel = entry.name
            button.addAction(UIAction { [weak self] _ in self?.onChange(.color(entry.hex)) }, for: .touchUpInside)
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            colorButtons.append(button)
            stack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(separator())

        let smaller = UIButton(type: .system, primaryAction: UIAction(image: UIImage(systemName: "textformat.size.smaller")) { [weak self] _ in self?.onChange(.size(-2)) })
        smaller.accessibilityLabel = "Smaller Text"
        let larger = UIButton(type: .system, primaryAction: UIAction(image: UIImage(systemName: "textformat.size.larger")) { [weak self] _ in self?.onChange(.size(2)) })
        larger.accessibilityLabel = "Larger Text"
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        sizeLabel.textColor = .secondaryLabel
        stack.addArrangedSubview(smaller)
        stack.addArrangedSubview(sizeLabel)
        stack.addArrangedSubview(larger)
        stack.addArrangedSubview(separator())

        alignmentControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onChange(.alignment(["left", "center", "right"][self.alignmentControl.selectedSegmentIndex]))
        }, for: .valueChanged)
        stack.addArrangedSubview(alignmentControl)
        stack.addArrangedSubview(separator())

        let done = UIButton(type: .system, primaryAction: UIAction(title: "Done") { [weak self] _ in self?.onChange(.done) })
        done.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        stack.addArrangedSubview(done)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func separator() -> UIView {
        let view = UIView()
        view.backgroundColor = .separator
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        view.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return view
    }

    func update(color: String, size: Double, alignment: String) {
        for (button, entry) in zip(colorButtons, ElementView.textColors) {
            let selected = entry.hex.caseInsensitiveCompare(color) == .orderedSame
            button.setImage(UIImage(systemName: selected ? "checkmark.circle.fill" : "circle.fill"), for: .normal)
        }
        sizeLabel.text = "\(Int(size))"
        alignmentControl.selectedSegmentIndex = ["left", "center", "right"].firstIndex(of: alignment) ?? 0
    }
}
