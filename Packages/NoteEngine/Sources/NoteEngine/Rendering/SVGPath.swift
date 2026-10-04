import CoreGraphics
import Foundation

/// Converts SVG path data (`d` attribute) into a `CGPath`.
///
/// Supports every SVG 1.1 path command: M L H V C S Q T A Z, in absolute and
/// relative forms. Malformed input stops parsing and returns what was read.
public enum SVGPath {
    public static func path(from data: String) -> CGPath {
        var scanner = Scanner(data)
        let path = CGMutablePath()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastControl: CGPoint?
        var lastCommand: Character = " "
        var command: Character = " "

        while let next = scanner.nextCommandOrNumber() {
            if case .command(let c) = next {
                command = c
            } else if command == " " {
                break
            } else {
                scanner.rewindNumber()
                // Extra coordinate pairs after M are implicit L.
                if command == "M" { command = "L" } else if command == "m" { command = "l" }
            }
            let relative = command.isLowercase
            func point() -> CGPoint? {
                guard let x = scanner.number(), let y = scanner.number() else { return nil }
                return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }

            switch command.uppercased().first! {
            case "M":
                guard let p = point() else { return path }
                path.move(to: p)
                current = p
                subpathStart = p
                lastControl = nil
            case "L":
                guard let p = point() else { return path }
                path.addLine(to: p)
                current = p
                lastControl = nil
            case "H":
                guard let x = scanner.number() else { return path }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
                lastControl = nil
            case "V":
                guard let y = scanner.number() else { return path }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
                lastControl = nil
            case "C":
                guard let c1 = point(), let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2)
                lastControl = c2
                current = p
            case "S":
                let reflectable = "CcSs".contains(lastCommand)
                let c1 = reflectable ? reflect(lastControl, around: current) : current
                guard let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2)
                lastControl = c2
                current = p
            case "Q":
                guard let c = point(), let p = point() else { return path }
                path.addQuadCurve(to: p, control: c)
                lastControl = c
                current = p
            case "T":
                let reflectable = "QqTt".contains(lastCommand)
                let c = reflectable ? reflect(lastControl, around: current) : current
                guard let p = point() else { return path }
                path.addQuadCurve(to: p, control: c)
                lastControl = c
                current = p
            case "A":
                guard let rx = scanner.number(), let ry = scanner.number(), let rotation = scanner.number(),
                      let largeArc = scanner.flag(), let sweep = scanner.flag(), let p = point() else { return path }
                addArc(to: path, from: current, to: p, rx: rx, ry: ry, rotation: rotation, largeArc: largeArc, sweep: sweep)
                current = p
                lastControl = nil
            case "Z":
                path.closeSubpath()
                current = subpathStart
                lastControl = nil
            default:
                return path
            }
            lastCommand = command
        }
        return path
    }

    private static func reflect(_ control: CGPoint?, around point: CGPoint) -> CGPoint {
        guard let control else { return point }
        return CGPoint(x: 2 * point.x - control.x, y: 2 * point.y - control.y)
    }

    /// Endpoint-to-center arc conversion from the SVG 1.1 implementation notes (F.6.5),
    /// emitted as cubic Béziers of at most 90° each.
    private static func addArc(to path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx: CGFloat, ry: CGFloat, rotation: CGFloat, largeArc: Bool, sweep: Bool) {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, p0 != p1 else {
            path.addLine(to: p1)
            return
        }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            rx *= sqrt(lambda)
            ry *= sqrt(lambda)
        }
        let numerator = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coefficient = sqrt(max(0, numerator / denominator))
        if largeArc == sweep { coefficient = -coefficient }
        let cxp = coefficient * rx * y1p / ry
        let cyp = -coefficient * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let t = 4.0 / 3.0 * tan(step / 4)
        var theta = theta1
        func point(_ angle: CGFloat) -> CGPoint {
            let x = rx * cos(angle), y = ry * sin(angle)
            return CGPoint(x: cx + cosPhi * x - sinPhi * y, y: cy + sinPhi * x + cosPhi * y)
        }
        func derivative(_ angle: CGFloat) -> CGPoint {
            let x = -rx * sin(angle), y = ry * cos(angle)
            return CGPoint(x: cosPhi * x - sinPhi * y, y: sinPhi * x + cosPhi * y)
        }
        for _ in 0..<segments {
            let start = point(theta), end = point(theta + step)
            let d1 = derivative(theta), d2 = derivative(theta + step)
            path.addCurve(
                to: end,
                control1: CGPoint(x: start.x + t * d1.x, y: start.y + t * d1.y),
                control2: CGPoint(x: end.x - t * d2.x, y: end.y - t * d2.y)
            )
            theta += step
        }
    }

    private enum Token {
        case command(Character)
        case number
    }

    private struct Scanner {
        let chars: [Character]
        var index = 0
        var lastNumberStart = 0

        init(_ s: String) { chars = Array(s) }

        mutating func skipSeparators() {
            while index < chars.count, chars[index] == " " || chars[index] == "," || chars[index] == "\n" || chars[index] == "\t" || chars[index] == "\r" {
                index += 1
            }
        }

        mutating func nextCommandOrNumber() -> Token? {
            skipSeparators()
            guard index < chars.count else { return nil }
            let c = chars[index]
            if c.isLetter, c != "e", c != "E" {
                index += 1
                return .command(c)
            }
            lastNumberStart = index
            return .number
        }

        mutating func rewindNumber() { index = lastNumberStart }

        mutating func flag() -> Bool? {
            skipSeparators()
            guard index < chars.count else { return nil }
            let c = chars[index]
            guard c == "0" || c == "1" else { return nil }
            index += 1
            return c == "1"
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            let start = index
            if index < chars.count, chars[index] == "-" || chars[index] == "+" { index += 1 }
            var sawDot = false, sawDigit = false
            while index < chars.count {
                let c = chars[index]
                if c.isNumber {
                    sawDigit = true
                } else if c == ".", !sawDot {
                    sawDot = true
                } else if c == "e" || c == "E" {
                    index += 1
                    if index < chars.count, chars[index] == "-" || chars[index] == "+" { index += 1 }
                    continue
                } else {
                    break
                }
                index += 1
            }
            guard sawDigit, let value = Double(String(chars[start..<index])) else {
                index = start
                return nil
            }
            return CGFloat(value)
        }
    }
}
