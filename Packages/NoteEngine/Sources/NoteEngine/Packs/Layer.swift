import Foundation

/// One drawing instruction in a paper, cover, or sticker.
///
/// Layers are drawn in order. Unknown `type`s are skipped, so packs written for
/// newer engines still open. Coordinates use a top-left origin.
///
/// | type | draws | main fields |
/// | --- | --- | --- |
/// | `fill` | solid color | `color`, optional `x y width height` |
/// | `gradient` | linear gradient | `colors`, `angle` |
/// | `hlines` / `vlines` | ruled lines | `spacing`, `top bottom left right`, `color`, `lineWidth` |
/// | `grid` | square grid | `spacing`, `majorEvery`, `majorColor` |
/// | `dots` | dot grid | `spacing`, `radius` |
/// | `isometric` | triangle grid | `spacing`, `style` (`lines` or `dots`) |
/// | `staff` | music staves | `spacing` (line gap), `staffGap` |
/// | `rect` / `ellipse` | shapes | `x y width height`, `fill`, `stroke`, `cornerRadius` |
/// | `star` | a star or regular polygon | `points`, `innerRatio`, `x y width height`, `fill`, `stroke` |
/// | `line` | a segment | `x1 y1 x2 y2` |
/// | `path` | SVG path data | `d`, `viewBox`, `x y width height` |
/// | `text` | text with `{{placeholders}}` | `text`, `fontSize`, `weight`, `design`, `align` |
/// | `image` / `pdf` | pack asset | `src`, `page` |
public struct Layer: Codable, Hashable, Sendable {
    public var type: String

    // Placement
    public var x: Length?
    public var y: Length?
    public var width: Length?
    public var height: Length?
    public var x1: Length?
    public var y1: Length?
    public var x2: Length?
    public var y2: Length?
    public var top: Length?
    public var bottom: Length?
    public var left: Length?
    public var right: Length?
    public var rotation: Double?
    public var opacity: Double?
    public var `repeat`: Repeat?

    // Patterns
    public var spacing: Length?
    public var radius: Length?
    public var majorEvery: Int?
    public var majorColor: String?
    public var majorWidth: Double?
    public var staffGap: Length?
    public var style: String?

    // Paint
    public var color: String?
    public var colors: [String]?
    public var angle: Double?
    public var fill: String?
    public var stroke: String?
    public var lineWidth: Double?
    public var dash: [Double]?
    public var cornerRadius: Length?

    // Content
    public var d: String?
    public var viewBox: [Double]?
    public var text: String?
    public var fontSize: Double?
    public var weight: String?
    public var design: String?
    public var align: String?
    public var src: String?
    public var page: Int?
    /// Points on a `star`; 5 by default. With `innerRatio` 1 it is a regular polygon.
    public var points: Int?
    /// Inner radius of a `star` as a fraction of the outer radius; 0.5 by default.
    public var innerRatio: Double?

    public init(type: String) {
        self.type = type
    }

    /// Draws the layer `count` times, offset by `dx`/`dy` each time.
    public struct Repeat: Codable, Hashable, Sendable {
        public var count: Int
        public var dx: Length?
        public var dy: Length?

        public init(count: Int, dx: Length? = nil, dy: Length? = nil) {
            self.count = count
            self.dx = dx
            self.dy = dy
        }
    }
}

/// A length in points, written as a number or a small expression.
///
/// Expressions support `+ - * /`, parentheses, percentages of the containing
/// axis (`50%`), and template parameters (`$spacing`). Examples: `72`,
/// `"100% - 36"`, `"$spacing * 2"`, `"50% - $margin / 2"`.
public enum Length: Codable, Hashable, Sendable, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral, ExpressibleByStringLiteral {
    case points(Double)
    case expression(String)

    public init(floatLiteral value: Double) { self = .points(value) }
    public init(integerLiteral value: Int) { self = .points(Double(value)) }
    public init(stringLiteral value: String) { self = .expression(value) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Double.self) {
            self = .points(n)
        } else {
            self = .expression(try c.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .points(let n): try c.encode(n)
        case .expression(let s): try c.encode(s)
        }
    }

    /// Resolves the length. `axis` is the size that `100%` refers to.
    public func resolve(axis: Double, parameters: [String: Double]) -> Double {
        switch self {
        case .points(let n):
            return n
        case .expression(let s):
            var parser = ExpressionParser(source: s, axis: axis, parameters: parameters)
            return parser.parse() ?? 0
        }
    }
}

/// Recursive-descent evaluator for `Length` expressions.
struct ExpressionParser {
    private let chars: [Character]
    private var index = 0
    private let axis: Double
    private let parameters: [String: Double]

    init(source: String, axis: Double, parameters: [String: Double]) {
        self.chars = Array(source)
        self.axis = axis
        self.parameters = parameters
    }

    mutating func parse() -> Double? {
        let value = expression()
        skipSpaces()
        return index == chars.count ? value : nil
    }

    private mutating func expression() -> Double? {
        guard var value = term() else { return nil }
        while true {
            skipSpaces()
            guard index < chars.count, chars[index] == "+" || chars[index] == "-" else { return value }
            let op = chars[index]
            index += 1
            guard let rhs = term() else { return nil }
            value = op == "+" ? value + rhs : value - rhs
        }
    }

    private mutating func term() -> Double? {
        guard var value = factor() else { return nil }
        while true {
            skipSpaces()
            guard index < chars.count, chars[index] == "*" || chars[index] == "/" else { return value }
            let op = chars[index]
            index += 1
            guard let rhs = factor() else { return nil }
            value = op == "*" ? value * rhs : (rhs == 0 ? 0 : value / rhs)
        }
    }

    private mutating func factor() -> Double? {
        skipSpaces()
        guard index < chars.count else { return nil }
        let c = chars[index]
        if c == "-" {
            index += 1
            return factor().map { -$0 }
        }
        if c == "(" {
            index += 1
            let value = expression()
            skipSpaces()
            guard index < chars.count, chars[index] == ")" else { return nil }
            index += 1
            return value
        }
        if c == "$" {
            index += 1
            var name = ""
            while index < chars.count, chars[index].isLetter || chars[index].isNumber || chars[index] == "_" {
                name.append(chars[index])
                index += 1
            }
            return parameters[name] ?? 0
        }
        var number = ""
        while index < chars.count, chars[index].isNumber || chars[index] == "." {
            number.append(chars[index])
            index += 1
        }
        guard var value = Double(number) else { return nil }
        if index < chars.count, chars[index] == "%" {
            index += 1
            value = axis * value / 100
        }
        return value
    }

    private mutating func skipSpaces() {
        while index < chars.count, chars[index] == " " { index += 1 }
    }
}
