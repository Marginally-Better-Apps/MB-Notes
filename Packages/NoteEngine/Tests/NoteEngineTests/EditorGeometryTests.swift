import CoreGraphics
import Foundation
import Testing
@testable import NoteEngine

@Suite struct PageLayoutTests {
    @Test func verticalStacksPages() {
        let layout = PageLayout(sizes: [.letter, .a4], axis: .vertical, gap: 10, margin: 5)
        #expect(layout.frames[0].origin == CGPoint(x: 5, y: 5))
        #expect(layout.frames[1].minY == 807.0)
        #expect(layout.documentSize.width == 622.0)
        #expect(layout.pageIndex(at: CGPoint(x: 100, y: 800)) == 0, "the gap belongs to the nearer page")
        #expect(layout.pageIndex(at: CGPoint(x: 100, y: 5000)) == 1, "past the end clamps to the last page")
    }

    @Test func horizontalLaysPagesSideBySide() {
        let layout = PageLayout(sizes: [.letter, .letter, .widescreen], axis: .horizontal, gap: 20, margin: 0)
        #expect(layout.frames[1].minX == 632.0)
        #expect(layout.frames[2].midY == layout.frames[0].midY, "pages are vertically centered")
        #expect(layout.documentSize.height == 792.0)
        #expect(layout.pageIndex(forStrokeBounds: CGRect(x: 640, y: 100, width: 10, height: 10)) == 1)
        #expect(layout.visiblePage(in: CGRect(x: 600, y: 0, width: 700, height: 792)) == 1)
        #expect(layout.offset(centering: 1, viewportLength: 800, zoom: 1) == 538.0)
        #expect(layout.offset(centering: 0, viewportLength: 2000, zoom: 1) == 0.0, "offsets never go negative")
    }
}

@Suite struct StrokeBeautifierTests {
    private func wobble(_ points: [CGPoint], amount: CGFloat = 1.5, seed: Int = 1) -> [CGPoint] {
        var state = UInt64(seed)
        func noise() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (CGFloat(state >> 33) / CGFloat(UInt32.max) - 0.5) * 2 * amount
        }
        return points.map { CGPoint(x: $0.x + noise(), y: $0.y + noise()) }
    }

    private func walk(_ corners: [CGPoint], close: Bool = false, stepsPerSide: Int = 30) -> [CGPoint] {
        var points: [CGPoint] = []
        let path = close ? corners + [corners[0]] : corners
        for (a, b) in zip(path, path.dropFirst()) {
            for i in 0..<stepsPerSide {
                let t = CGFloat(i) / CGFloat(stepsPerSide)
                points.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        points.append(path[path.count - 1])
        return points
    }

    @Test func nearlyStraightStrokeBecomesALineSnappedToTheAxis() throws {
        let stroke = wobble(walk([CGPoint(x: 10, y: 100), CGPoint(x: 300, y: 104)]))
        let shape = try #require(StrokeBeautifier.fit(stroke))
        guard case .line(let a, let b) = shape else { Issue.record("expected a line, got \(shape)"); return }
        #expect(abs(a.y - b.y) < 0.5, "a 1° tilt snaps to horizontal")
        #expect(abs(b.x - 300) < 3)
    }

    @Test func shortStrokesAreLeftAlone() {
        #expect(StrokeBeautifier.fit(walk([CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 5)])) == nil)
    }

    @Test func rectangleGetsRightAngles() throws {
        let stroke = wobble(walk([CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 104), CGPoint(x: 296, y: 220), CGPoint(x: 103, y: 216)], close: true), amount: 2)
        let shape = try #require(StrokeBeautifier.fit(stroke))
        guard case .polygon(let corners) = shape else { Issue.record("expected a polygon, got \(shape)"); return }
        #expect(corners.count == 4)
        for i in 0..<corners.count {
            #expect(abs(StrokeBeautifier.interiorAngle(corners, at: i) - .pi / 2) < 0.01)
        }
        #expect(abs(corners[0].x - corners[3].x) < 0.01, "axis-aligned rectangles snap to the axes")
    }

    @Test func triangleKeepsThreeCorners() throws {
        let stroke = wobble(walk([CGPoint(x: 100, y: 300), CGPoint(x: 300, y: 300), CGPoint(x: 200, y: 120)], close: true))
        let shape = try #require(StrokeBeautifier.fit(stroke))
        guard case .polygon(let corners) = shape else { Issue.record("expected a polygon, got \(shape)"); return }
        #expect(corners.count == 3)
    }

    @Test func circleBecomesACircle() throws {
        let stroke = wobble((0...80).map { i in
            let t = CGFloat(i) / 80 * 2 * .pi
            return CGPoint(x: 200 + cos(t) * 80, y: 200 + sin(t) * 82)
        }, amount: 2)
        let shape = try #require(StrokeBeautifier.fit(stroke))
        guard case .ellipse(let center, let rx, let ry, _) = shape else { Issue.record("expected an ellipse, got \(shape)"); return }
        #expect(rx == ry, "nearly round loops snap to circles")
        #expect(abs(center.x - 200) < 3 && abs(center.y - 200) < 3)
        #expect(abs(rx - 81) < 6)
    }

    @Test func singleStrokeArrowFindsItsTip() throws {
        // A shaft to the right, then a short tail back up-left: a hand-drawn arrowhead.
        let stroke = wobble(walk([CGPoint(x: 50, y: 200), CGPoint(x: 300, y: 200), CGPoint(x: 270, y: 180)], stepsPerSide: 30), amount: 1)
        let shape = try #require(StrokeBeautifier.fit(stroke))
        guard case .arrow(let from, let to) = shape else { Issue.record("expected an arrow, got \(shape)"); return }
        #expect(abs(from.x - 50) < 3)
        #expect(abs(to.x - 300) < 6)
        #expect(shape.arrowhead.count == 2)
    }

    @Test func caretStrokeTurnsALineIntoAnArrow() throws {
        let line = StrokeBeautifier.Shape.line(from: CGPoint(x: 50, y: 200), to: CGPoint(x: 300, y: 200))
        let caret = walk([CGPoint(x: 280, y: 180), CGPoint(x: 300, y: 200), CGPoint(x: 280, y: 220)], stepsPerSide: 10)
        let merged = try #require(StrokeBeautifier.mergeArrowhead(previous: line, caret: caret))
        guard case .arrow(_, let to) = merged else { Issue.record("expected an arrow, got \(merged)"); return }
        #expect(to == CGPoint(x: 300, y: 200))
        let farAway = walk([CGPoint(x: 100, y: 400), CGPoint(x: 120, y: 420), CGPoint(x: 100, y: 440)], stepsPerSide: 10)
        #expect(StrokeBeautifier.mergeArrowhead(previous: line, caret: farAway) == nil)
    }

    @Test func elbowConnectorKeepsItsCorner() throws {
        let stroke = wobble(walk([CGPoint(x: 50, y: 50), CGPoint(x: 250, y: 52), CGPoint(x: 252, y: 250)]), amount: 1)
        let shape = try #require(StrokeBeautifier.fit(stroke))
        guard case .polyline(let points) = shape else { Issue.record("expected a polyline, got \(shape)"); return }
        #expect(points.count == 3)
        #expect(abs(points[1].y - points[0].y) < 0.5 && abs(points[2].x - points[1].x) < 0.5, "both legs snap to the axes")
    }

    @Test func regularHexagonIsMadeRegular() throws {
        let corners = (0..<6).map { i -> CGPoint in
            let t = CGFloat(i) / 6 * 2 * .pi
            return CGPoint(x: 200 + cos(t) * (100 + CGFloat(i % 2) * 8), y: 200 + sin(t) * 100)
        }
        let shape = try #require(StrokeBeautifier.fit(wobble(walk(corners, close: true, stepsPerSide: 20))))
        guard case .polygon(let fitted) = shape else { Issue.record("expected a polygon, got \(shape)"); return }
        #expect(fitted.count == 6)
        let cx = fitted.map(\.x).reduce(0, +) / 6, cy = fitted.map(\.y).reduce(0, +) / 6
        let radii = fitted.map { hypot($0.x - cx, $0.y - cy) }
        #expect((radii.max()! - radii.min()!) < 0.01, "vertices land on one circle around the fitted center")
        let sides = (0..<6).map { i in hypot(fitted[(i + 1) % 6].x - fitted[i].x, fitted[(i + 1) % 6].y - fitted[i].y) }
        #expect((sides.max()! - sides.min()!) < 0.01, "all sides are equal")
    }
}
