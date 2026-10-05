import Foundation

/// `pack.json`, the manifest at the root of a `.mbpack` content pack.
///
/// Every list can hold inline objects or relative paths to JSON files inside
/// the pack, so large packs can keep one item per file:
///
/// ```json
/// { "papers": ["papers/cornell.json", { "id": "blank", "name": "Blank", "layers": [] }] }
/// ```
///
/// See docs/PACKS.md for the authoring guide.
public struct PackManifest: Codable, Sendable {
    public static let currentFormat = "mbnotes.pack/1"

    public var format: String
    public var id: String
    public var name: String
    public var version: String
    public var author: String?
    public var description: String?
    public var license: String?
    public var homepage: String?
    /// Lowest engine version the pack needs, such as `1.0`.
    public var minimumEngineVersion: String?
    public var papers: [Include<PaperTemplate>]
    public var covers: [Include<CoverDesign>]
    public var stickers: [Include<StickerDefinition>]
    public var palettes: [Include<Palette>]
    public var symbolSets: [Include<SymbolSet>]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? Self.currentFormat
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? "1.0.0"
        author = try c.decodeIfPresent(String.self, forKey: .author)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        license = try c.decodeIfPresent(String.self, forKey: .license)
        homepage = try c.decodeIfPresent(String.self, forKey: .homepage)
        minimumEngineVersion = try c.decodeIfPresent(String.self, forKey: .minimumEngineVersion)
        papers = try c.decodeIfPresent([Include<PaperTemplate>].self, forKey: .papers) ?? []
        covers = try c.decodeIfPresent([Include<CoverDesign>].self, forKey: .covers) ?? []
        stickers = try c.decodeIfPresent([Include<StickerDefinition>].self, forKey: .stickers) ?? []
        palettes = try c.decodeIfPresent([Include<Palette>].self, forKey: .palettes) ?? []
        symbolSets = try c.decodeIfPresent([Include<SymbolSet>].self, forKey: .symbolSets) ?? []
    }
}

/// Either an inline value or a pack-relative path to a JSON file holding one.
public enum Include<Value: Codable & Sendable>: Codable, Sendable {
    case inline(Value)
    case file(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let path = try? c.decode(String.self) {
            self = .file(path)
        } else {
            self = .inline(try c.decode(Value.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .inline(let value): try c.encode(value)
        case .file(let path): try c.encode(path)
        }
    }
}

public enum PaperRole: String, Codable, Sendable {
    /// An ordinary writing page.
    case page
    /// A decorated first page for notebooks.
    case title
}

/// A page background described as drawing layers.
public struct PaperTemplate: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var category: String
    public var role: PaperRole
    public var size: PageSize?
    public var background: String
    public var layers: [Layer]
    public var parameters: [String: TemplateParameter]
    public var tags: [String]

    public init(id: String, name: String, category: String = "Basic", role: PaperRole = .page, size: PageSize? = nil, background: String = "#FFFFFF", layers: [Layer] = [], parameters: [String: TemplateParameter] = [:], tags: [String] = []) {
        self.id = id
        self.name = name
        self.category = category
        self.role = role
        self.size = size
        self.background = background
        self.layers = layers
        self.parameters = parameters
        self.tags = tags
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? "Basic"
        role = try c.decodeIfPresent(PaperRole.self, forKey: .role) ?? .page
        size = try c.decodeIfPresent(PageSize.self, forKey: .size)
        background = try c.decodeIfPresent(String.self, forKey: .background) ?? "#FFFFFF"
        layers = try c.decodeIfPresent([Layer].self, forKey: .layers) ?? []
        parameters = try c.decodeIfPresent([String: TemplateParameter].self, forKey: .parameters) ?? [:]
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
    }
}

/// A user-adjustable number a template's layers reference as `$name`.
public struct TemplateParameter: Codable, Hashable, Sendable {
    public var label: String
    public var defaultValue: Double
    public var minimum: Double?
    public var maximum: Double?
    public var step: Double?

    enum CodingKeys: String, CodingKey {
        case label, minimum = "min", maximum = "max", step
        case defaultValue = "default"
    }

    public init(label: String, defaultValue: Double, minimum: Double? = nil, maximum: Double? = nil, step: Double? = nil) {
        self.label = label
        self.defaultValue = defaultValue
        self.minimum = minimum
        self.maximum = maximum
        self.step = step
    }
}

/// A notebook cover, drawn with the same layers as paper on a 300 × 400 canvas.
public struct CoverDesign: Codable, Hashable, Sendable, Identifiable {
    public static let canvasSize = PageSize(width: 300, height: 400)

    public var id: String
    public var name: String
    /// Suggested accent color when this cover is picked.
    public var defaultColor: String?
    public var background: String
    public var layers: [Layer]

    public init(id: String, name: String, defaultColor: String? = nil, background: String = "accent", layers: [Layer] = []) {
        self.id = id
        self.name = name
        self.defaultColor = defaultColor
        self.background = background
        self.layers = layers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        defaultColor = try c.decodeIfPresent(String.self, forKey: .defaultColor)
        background = try c.decodeIfPresent(String.self, forKey: .background) ?? "accent"
        layers = try c.decodeIfPresent([Layer].self, forKey: .layers) ?? []
    }
}

/// A sticker. Exactly one of `emoji`, `image`, or `layers` describes its art.
public struct StickerDefinition: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var category: String
    public var emoji: String?
    /// A PNG, JPEG, or PDF inside the pack.
    public var image: String?
    /// Vector art drawn on `canvas`.
    public var layers: [Layer]?
    public var canvas: PageSize?
    /// Search keywords beyond the name.
    public var tags: [String]
    /// Draws a white die-cut border around the art.
    public var outlined: Bool

    public init(id: String, name: String, category: String = "Fun", emoji: String? = nil, image: String? = nil, layers: [Layer]? = nil, canvas: PageSize? = nil, tags: [String] = [], outlined: Bool = true) {
        self.id = id
        self.name = name
        self.category = category
        self.emoji = emoji
        self.tags = tags
        self.image = image
        self.layers = layers
        self.canvas = canvas
        self.outlined = outlined
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? "Fun"
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji)
        image = try c.decodeIfPresent(String.self, forKey: .image)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        layers = try c.decodeIfPresent([Layer].self, forKey: .layers)
        canvas = try c.decodeIfPresent(PageSize.self, forKey: .canvas)
        outlined = try c.decodeIfPresent(Bool.self, forKey: .outlined) ?? true
    }
}

public struct Palette: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var colors: [String]

    public init(id: String, name: String, colors: [String]) {
        self.id = id
        self.name = name
        self.colors = colors
    }
}

/// SF Symbols offered for folder icons, grouped by theme.
public struct SymbolSet: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var symbols: [String]

    public init(id: String, name: String, symbols: [String]) {
        self.id = id
        self.name = name
        self.symbols = symbols
    }
}
