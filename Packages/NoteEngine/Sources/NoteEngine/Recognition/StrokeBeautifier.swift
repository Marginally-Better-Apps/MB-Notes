import CoreGraphics
import Foundation

/// Turns a rough hand-drawn stroke into a clean shape, deterministically.
///
/// The pipeline: resample by arc length, find corners (a straw-style curvature test),
/// then decide between a line, an elbow connector, an arrow, a polygon, or an ellipse
/// from the corner count and how closed the stroke is. Everything is plain geometry,
/// so it is fast, predictable, and needs no model.
public enum StrokeBeautifier {
    public enum Shape: Equatable, Sendable {
        case line(from: CGPoint, to: CGPoint)
        /// A line with an arrowhead at `to`.
        case arrow(from: CGPoint, to: CGPoint)
        /// Two or more straight segments through corners, such as a right-angle connector.
        case polyline([CGPoint])
        /// A closed shape with straight sides, in drawing order.
        case polygon([CGPoint])
        case ellipse(center: CGPoint, radiusX: CGFloat, radiusY: CGFloat, rotation: CGFloat)

        /// Points to feed back to the canvas as a stroke, closed where the shape is closed.
        public var outline: [CGPoint] {
            switch self {
            case .line(let a, let b), .arrow(let a, let b): return [a, b]
            case .polyline(let points): return points
            case .polygon(let points): return points + [points[0]]
            case .ellipse(let center, let rx, let ry, let rotation):
                return (0...64).map { i in
                    let t = CGFloat(i) / 64 * 2 * .pi
                    let x = cos(t) * rx, y = sin(t) * ry
                    return CGPoint(x: center.x + x * cos(rotation) - y * sin(rotation), y: center.y + x * sin(rotation) + y * cos(rotation))
                }
            }
        }

        /// The arrowhead for `.arrow`, as two short strokes meeting at the tip.
        public var arrowhead: [[CGPoint]] {
            guard case .arrow(let from, let to) = self else { return [] }
            let angle = atan2(to.y - from.y, to.x - from.x)
            let length = min(28, max(12, hypot(to.x - from.x, to.y - from.y) * 0.18))
            func wing(_ delta: CGFloat) -> CGPoint {
                CGPoint(x: to.x - cos(angle + delta) * length, y: to.y - sin(angle + delta) * length)
            }
            return [[wing(0.5), to], [wing(-0.5), to]]
        }
    }

    public struct Options: Sendable {
        /// Strokes shorter than this (points) are left alone; they are usually handwriting.
        public var minimumLength: CGFloat = 40
        /// Snap line angles to multiples of 45° when within this many degrees.
        public var angleSnapDegrees: CGFloat = 6
        /// Treat a stroke as closed when its ends are within this fraction of its length.
        public var closedFraction: CGFloat = 0.18

        public init() {}
    }

    /// Fits a shape to raw stroke points, or nil when the stroke does not look like one.
    public static func fit(_ raw: [CGPoint], options: Options = Options()) -> Shape? {
        let points = resample(raw, count: 96)
        guard points.count >= 8 else { return nil }
        let length = pathLength(points)
        guard length >= options.minimumLength else { return nil }
        let endGap = hypot(points[0].x - points[points.count - 1].x, points[0].y - points[points.count - 1].y)
        let closed = endGap < length * options.closedFraction
        let corners = cornerIndices(points, cyclic: closed)

        if !closed {
            return fitOpen(points, corners: corners, length: length, options: options)
        }
        return fitClosed(points, corners: corners, length: length)
    }

    // MARK: Open strokes

    private static func fitOpen(_ points: [CGPoint], corners: [Int], length: CGFloat, options: Options) -> Shape? {
        let start = points[0], end = points[points.count - 1]
        let straightness = hypot(end.x - start.x, end.y - start.y) / length
        if corners.isEmpty, straightness > 0.96 {
            return .line(from: start, to: snapAngle(from: start, to: end, within: options.angleSnapDegrees))
        }
        // A single-stroke arrow: a shaft, then a sharp turn into a short tail that doubles back.
        if let arrow = fitSingleStrokeArrow(points, corners: corners, length: length, options: options) {
            return arrow
        }
        // Straight segments between corners: an elbow connector or a zigzag.
        if !corners.isEmpty, corners.count <= 3 {
            let vertices = [start] + corners.map { points[$0] } + [end]
            if segmentsAreStraight(points, vertices: vertices, cornerIndices: [0] + corners + [points.count - 1]) {
                var snapped = [vertices[0]]
                for i in 1..<vertices.count { snapped.append(snapAngle(from: snapped[i - 1], to: vertices[i], within: options.angleSnapDegrees)) }
                return .polyline(snapped)
            }
        }
        return nil
    }

    /// An arrow drawn as one stroke ends with a short "V": the last corner is the tip, and the
    /// final run is short and points back along the shaft.
    private static func fitSingleStrokeArrow(_ points: [CGPoint], corners: [Int], length: CGFloat, options: Options) -> Shape? {
        guard let tipIndex = corners.last, corners.count <= 3 else { return nil }
        let tip = points[tipIndex]
        let start = points[0]
        let end = points[points.count - 1]
        let tail = pathLength(Array(points[tipIndex...]))
        let shaft = pathLength(Array(points[...tipIndex]))
        guard tail > 6, tail < shaft * 0.45 else { return nil }
        // The tail must point back toward the shaft (angle between shaft and tail > 100°).
        let shaftAngle = atan2(tip.y - start.y, tip.x - start.x)
        let tailAngle = atan2(end.y - tip.y, end.x - tip.x)
        var turn = abs(tailAngle - shaftAngle)
        if turn > .pi { turn = 2 * .pi - turn }
        guard turn > 1.75 else { return nil }
        // The shaft itself should be reasonably straight.
        let shaftStraightness = hypot(tip.x - start.x, tip.y - start.y) / max(shaft, 1)
        guard shaftStraightness > 0.9 else { return nil }
        return .arrow(from: start, to: snapAngle(from: start, to: tip, within: options.angleSnapDegrees))
    }

    /// Merges a short "V" or caret stroke onto a line drawn just before it, making an arrow.
    /// `previous` is the shape already on the page; `caret` the new stroke's points.
    public static func mergeArrowhead(previous: Shape, caret: [CGPoint], tolerance: CGFloat = 24) -> Shape? {
        guard case .line(let from, let to) = previous else { return nil }
        let points = resample(caret, count: 24)
        guard points.count >= 4 else { return nil }
        let length = pathLength(points)
        let lineLength = hypot(to.x - from.x, to.y - from.y)
        guard length < lineLength * 0.6 else { return nil }
        // The caret's apex (point farthest from the segment joining its ends) must sit near a line end.
        let a = points[0], b = points[points.count - 1]
        guard let apex = points.max(by: { distance($0, toSegment: a, b) < distance($1, toSegment: a, b) }) else { return nil }
        let nearEnd = hypot(apex.x - to.x, apex.y - to.y) < tolerance
        let nearStart = hypot(apex.x - from.x, apex.y - from.y) < tolerance
        if nearEnd { return .arrow(from: from, to: to) }
        if nearStart { return .arrow(from: to, to: from) }
        return nil
    }

    // MARK: Closed strokes

    private static func fitClosed(_ points: [CGPoint], corners: [Int], length: CGFloat) -> Shape? {
        let vertices = corners.map { points[$0] }
        switch corners.count {
        case 0, 1, 2:
            return fitEllipse(points)
        case 3:
            return .polygon(vertices)
        case 4:
            return .polygon(regularizeQuadrilateral(vertices))
        case 5...8:
            return .polygon(regularizePolygon(vertices))
        case 9...12:
            // Alternating in/out corners read as a star; keep its drawn geometry but even it out.
            return .polygon(regularizeStar(vertices))
        default:
            return fitEllipse(points)
        }
    }

    /// Direct least-squares ellipse fit (Fitzgibbon), reduced to the bounding-box/moment form
    /// that is stable for hand-drawn loops. Snaps to a circle when nearly round.
    static func fitEllipse(_ points: [CGPoint]) -> Shape? {
        let n = CGFloat(points.count)
        let cx = points.map(\.x).reduce(0, +) / n
        let cy = points.map(\.y).reduce(0, +) / n
        var sxx: CGFloat = 0, syy: CGFloat = 0, sxy: CGFloat = 0
        for p in points {
            let dx = p.x - cx, dy = p.y - cy
            sxx += dx * dx; syy += dy * dy; sxy += dx * dy
        }
        sxx /= n; syy /= n; sxy /= n
        let theta = 0.5 * atan2(2 * sxy, sxx - syy)
        let common = (sxx + syy) / 2
        let diff = sqrt(((sxx - syy) / 2) * ((sxx - syy) / 2) + sxy * sxy)
        // Second moments of a uniform ellipse outline relate to radii by a factor of √2.
        var rx = sqrt(max(common + diff, 0.01)) * sqrt(2)
        var ry = sqrt(max(common - diff, 0.01)) * sqrt(2)
        guard rx > 4, ry > 4 else { return nil }
        var rotation = theta
        if min(rx, ry) / max(rx, ry) > 0.88 {
            let r = (rx + ry) / 2
            rx = r; ry = r; rotation = 0
        } else if abs(rotation) < 0.12 || abs(abs(rotation) - .pi / 2) < 0.12 {
            // Nearly axis-aligned: make it exactly so.
            if abs(rotation) >= .pi / 4 { swap(&rx, &ry) }
            rotation = 0
        }
        return .ellipse(center: CGPoint(x: cx, y: cy), radiusX: rx, radiusY: ry, rotation: rotation)
    }

    /// Squares, rectangles, and diamonds get right angles; other quads keep their shape.
    static func regularizeQuadrilateral(_ v: [CGPoint]) -> [CGPoint] {
        let angles = (0..<4).map { interiorAngle(v, at: $0) }
        let rightAngles = angles.allSatisfy { abs($0 - .pi / 2) < 0.3 }
        guard rightAngles else { return v }
        // Fit a rotated rectangle: average the two edge directions, then project corners.
        let e0 = CGPoint(x: v[1].x - v[0].x, y: v[1].y - v[0].y)
        let e2 = CGPoint(x: v[2].x - v[3].x, y: v[2].y - v[3].y)
        var angle = atan2(e0.y + e2.y, e0.x + e2.x)
        // Snap near-axis rectangles to the axes.
        let snapped = (angle / (.pi / 2)).rounded() * (.pi / 2)
        if abs(angle - snapped) < 0.12 { angle = snapped }
        let cx = v.map(\.x).reduce(0, +) / 4, cy = v.map(\.y).reduce(0, +) / 4
        let ux = CGPoint(x: cos(angle), y: sin(angle)), uy = CGPoint(x: -sin(angle), y: cos(angle))
        var halfW: CGFloat = 0, halfH: CGFloat = 0
        for p in v {
            halfW += abs((p.x - cx) * ux.x + (p.y - cy) * ux.y)
            halfH += abs((p.x - cx) * uy.x + (p.y - cy) * uy.y)
        }
        halfW /= 4; halfH /= 4
        if abs(halfW - halfH) < max(halfW, halfH) * 0.1 { halfW = (halfW + halfH) / 2; halfH = halfW }
        let signs: [(CGFloat, CGFloat)] = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
        // Keep the drawn winding by matching each original corner to its nearest ideal corner.
        let ideal = signs.map { s in CGPoint(x: cx + s.0 * halfW * ux.x + s.1 * halfH * uy.x, y: cy + s.0 * halfW * ux.y + s.1 * halfH * uy.y) }
        return v.map { p in ideal.min { hypot($0.x - p.x, $0.y - p.y) < hypot($1.x - p.x, $1.y - p.y) }! }
    }

    /// Makes a polygon regular when its sides and angles are already close to equal.
    static func regularizePolygon(_ v: [CGPoint]) -> [CGPoint] {
        let sides = (0..<v.count).map { i in hypot(v[(i + 1) % v.count].x - v[i].x, v[(i + 1) % v.count].y - v[i].y) }
        let mean = sides.reduce(0, +) / CGFloat(sides.count)
        let variation = sides.map { abs($0 - mean) / mean }.max() ?? 1
        guard variation < 0.3 else { return v }
        let cx = v.map(\.x).reduce(0, +) / CGFloat(v.count), cy = v.map(\.y).reduce(0, +) / CGFloat(v.count)
        let radius = v.map { hypot($0.x - cx, $0.y - cy) }.reduce(0, +) / CGFloat(v.count)
        let startAngle = atan2(v[0].y - cy, v[0].x - cx)
        let clockwise = signedArea(v) > 0
        return (0..<v.count).map { i in
            let angle = startAngle + (clockwise ? 1 : -1) * CGFloat(i) * 2 * .pi / CGFloat(v.count)
            return CGPoint(x: cx + cos(angle) * radius, y: cy + sin(angle) * radius)
        }
    }

    /// Evens out a star drawn with alternating outer and inner points.
    static func regularizeStar(_ v: [CGPoint]) -> [CGPoint] {
        guard v.count % 2 == 0 else { return v }
        let cx = v.map(\.x).reduce(0, +) / CGFloat(v.count), cy = v.map(\.y).reduce(0, +) / CGFloat(v.count)
        let radii = v.map { hypot($0.x - cx, $0.y - cy) }
        let evenMean = stride(from: 0, to: v.count, by: 2).map { radii[$0] }.reduce(0, +) / CGFloat(v.count / 2)
        let oddMean = stride(from: 1, to: v.count, by: 2).map { radii[$0] }.reduce(0, +) / CGFloat(v.count / 2)
        guard max(evenMean, oddMean) > min(evenMean, oddMean) * 1.3 else { return regularizePolygon(v) }
        let outerFirst = evenMean > oddMean
        let startAngle = atan2(v[0].y - cy, v[0].x - cx)
        let clockwise = signedArea(v) > 0
        return (0..<v.count).map { i in
            let angle = startAngle + (clockwise ? 1 : -1) * CGFloat(i) * 2 * .pi / CGFloat(v.count)
            let radius = (i % 2 == 0) == outerFirst ? max(evenMean, oddMean) : min(evenMean, oddMean)
            return CGPoint(x: cx + cos(angle) * radius, y: cy + sin(angle) * radius)
        }
    }

    // MARK: Geometry helpers

    /// Resamples a path to `count` points spaced evenly along its length.
    static func resample(_ points: [CGPoint], count: Int) -> [CGPoint] {
        guard points.count >= 2 else { return points }
        let total = pathLength(points)
        guard total > 0 else { return [points[0]] }
        let step = total / CGFloat(count - 1)
        var result = [points[0]]
        var carry: CGFloat = 0
        var previous = points[0]
        for point in points.dropFirst() {
            var segment = hypot(point.x - previous.x, point.y - previous.y)
            var from = previous
            while carry + segment >= step, result.count < count {
                let t = (step - carry) / segment
                let next = CGPoint(x: from.x + (point.x - from.x) * t, y: from.y + (point.y - from.y) * t)
                result.append(next)
                segment -= step - carry
                carry = 0
                from = next
            }
            carry += segment
            previous = point
        }
        if result.count < count { result.append(points[points.count - 1]) }
        return result
    }

    static func pathLength(_ points: [CGPoint]) -> CGFloat {
        guard points.count > 1 else { return 0 }
        return zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    /// Corner detection in the spirit of ShortStraw: a point is a corner when the straight
    /// "straw" across its neighbors is much shorter than the path between them, and it is a
    /// local minimum of that ratio. Closed strokes are treated as a loop so a corner at the
    /// start of the stroke still counts.
    static func cornerIndices(_ points: [CGPoint], cyclic: Bool = false, window: Int = 4, threshold: CGFloat = 0.93) -> [Int] {
        let n = points.count
        guard n > window * 2 + 1 else { return [] }
        func at(_ i: Int) -> CGPoint { points[((i % n) + n) % n] }
        var ratio = [CGFloat](repeating: 1, count: n)
        let range = cyclic ? 0..<n : window..<(n - window)
        for i in range {
            let a = at(i - window), b = at(i + window)
            let straw = hypot(b.x - a.x, b.y - a.y)
            var path: CGFloat = 0
            for k in (i - window)..<(i + window) {
                let p = at(k), q = at(k + 1)
                path += hypot(q.x - p.x, q.y - p.y)
            }
            ratio[i] = path > 0 ? straw / path : 1
        }
        // Start scanning from a non-corner so no run of corners wraps around the end.
        let start = cyclic ? (ratio.firstIndex { $0 >= threshold } ?? 0) : window
        let count = cyclic ? n : n - window * 2
        var corners: [Int] = []
        var k = 0
        while k < count {
            let i = (start + k) % n
            if ratio[i] < threshold {
                var best = i
                var j = k
                while j < count, ratio[(start + j) % n] < threshold {
                    let idx = (start + j) % n
                    if ratio[idx] < ratio[best] { best = idx }
                    j += 1
                }
                corners.append(best)
                k = j
            } else {
                k += 1
            }
        }
        // Merge corners that are too close together (within the window), keeping the sharper one.
        var merged: [Int] = []
        for corner in corners {
            if let last = merged.last, (corner - last + n) % n <= window * 2 {
                if ratio[corner] < ratio[last] { merged[merged.count - 1] = corner }
            } else {
                merged.append(corner)
            }
        }
        if cyclic, merged.count > 1, let first = merged.first, let last = merged.last, (first - last + n) % n <= window * 2 {
            if ratio[last] < ratio[first] { merged[0] = last }
            merged.removeLast()
        }
        return cyclic ? merged.sorted() : merged
    }

    /// Whether each run between consecutive vertices is straight enough to be a segment.
    static func segmentsAreStraight(_ points: [CGPoint], vertices: [CGPoint], cornerIndices: [Int]) -> Bool {
        for (a, b) in zip(cornerIndices, cornerIndices.dropFirst()) {
            let run = Array(points[a...b])
            let chord = hypot(run[run.count - 1].x - run[0].x, run[run.count - 1].y - run[0].y)
            let length = pathLength(run)
            if length > 0, chord / length < 0.93 { return false }
        }
        return true
    }

    static func snapAngle(from: CGPoint, to: CGPoint, within degrees: CGFloat) -> CGPoint {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let step: CGFloat = .pi / 4
        let snapped = (angle / step).rounded() * step
        guard abs(angle - snapped) < degrees * .pi / 180 else { return to }
        let length = hypot(to.x - from.x, to.y - from.y)
        return CGPoint(x: from.x + cos(snapped) * length, y: from.y + sin(snapped) * length)
    }

    static func interiorAngle(_ v: [CGPoint], at i: Int) -> CGFloat {
        let p = v[(i + v.count - 1) % v.count], c = v[i], n = v[(i + 1) % v.count]
        let a = CGPoint(x: p.x - c.x, y: p.y - c.y), b = CGPoint(x: n.x - c.x, y: n.y - c.y)
        let dot = a.x * b.x + a.y * b.y
        let mags = hypot(a.x, a.y) * hypot(b.x, b.y)
        return acos(max(-1, min(1, dot / max(mags, 0.0001))))
    }

    static func signedArea(_ v: [CGPoint]) -> CGFloat {
        var area: CGFloat = 0
        for i in 0..<v.count {
            let a = v[i], b = v[(i + 1) % v.count]
            area += a.x * b.y - b.x * a.y
        }
        return area / 2
    }

    static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
