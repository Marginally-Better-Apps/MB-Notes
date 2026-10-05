import CoreGraphics
import Foundation

/// Where each page sits in document coordinates (points at 100% zoom).
///
/// Pages flow top to bottom (continuous scrolling) or left to right (side by side).
/// Everything in the editor that maps between pages and the canvas goes through this,
/// so switching the axis changes one place.
public struct PageLayout: Equatable, Sendable {
    public enum Axis: String, Sendable, CaseIterable {
        case vertical, horizontal
    }

    public let axis: Axis
    public let frames: [CGRect]
    public let documentSize: CGSize
    public let gap: CGFloat
    public let margin: CGFloat

    public init(sizes: [PageSize], axis: Axis, gap: CGFloat = 28, margin: CGFloat = 24) {
        self.axis = axis
        self.gap = gap
        self.margin = margin
        var frames: [CGRect] = []
        switch axis {
        case .vertical:
            let width = (sizes.map(\.width).max() ?? 612) + margin * 2
            var y = margin
            for size in sizes {
                frames.append(CGRect(x: (width - size.width) / 2, y: y, width: size.width, height: size.height))
                y += size.height + gap
            }
            self.frames = frames
            documentSize = CGSize(width: width, height: max(y - gap + margin, margin * 2))
        case .horizontal:
            let height = (sizes.map(\.height).max() ?? 792) + margin * 2
            var x = margin
            for size in sizes {
                frames.append(CGRect(x: x, y: (height - size.height) / 2, width: size.width, height: size.height))
                x += size.width + gap
            }
            self.frames = frames
            documentSize = CGSize(width: max(x - gap + margin, margin * 2), height: height)
        }
    }

    /// The page whose span along the axis contains `point`, or the nearest one.
    public func pageIndex(at point: CGPoint) -> Int? {
        guard !frames.isEmpty else { return nil }
        let value = axis == .vertical ? point.y : point.x
        if let exact = frames.firstIndex(where: { span($0).contains(value) }) { return exact }
        return frames.indices.min { distance(from: value, to: frames[$0]) < distance(from: value, to: frames[$1]) }
    }

    /// The page that owns a stroke drawn at `bounds`: the one its center lands on, including the gap.
    public func pageIndex(forStrokeBounds bounds: CGRect) -> Int? {
        pageIndex(at: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    /// The page that fills most of a viewport, for the page indicator.
    public func visiblePage(in viewport: CGRect) -> Int? {
        guard !frames.isEmpty else { return nil }
        let center = axis == .vertical ? viewport.midY : viewport.midX
        return pageIndex(at: CGPoint(x: center, y: center))
    }

    /// The offset along the axis that centers a page in a viewport of `viewportLength`,
    /// clamped to the document. Used for snapping in side-by-side mode.
    public func offset(centering index: Int, viewportLength: CGFloat, zoom: CGFloat) -> CGFloat {
        guard let frame = frames[safe: index] else { return 0 }
        let start = (axis == .vertical ? frame.minY : frame.minX) * zoom
        let length = (axis == .vertical ? frame.height : frame.width) * zoom
        let total = (axis == .vertical ? documentSize.height : documentSize.width) * zoom
        let centered = start - (viewportLength - length) / 2
        return min(max(0, centered), max(0, total - viewportLength))
    }

    private func span(_ frame: CGRect) -> ClosedRange<CGFloat> {
        let half = gap / 2
        return axis == .vertical ? (frame.minY - half)...(frame.maxY + half) : (frame.minX - half)...(frame.maxX + half)
    }

    private func distance(from value: CGFloat, to frame: CGRect) -> CGFloat {
        let range = span(frame)
        if range.contains(value) { return 0 }
        return min(abs(value - range.lowerBound), abs(value - range.upperBound))
    }
}

public extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
