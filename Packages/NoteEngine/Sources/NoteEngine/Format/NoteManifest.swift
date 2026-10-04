import Foundation

/// The root of a `.mbnote` package, stored as `document.json`.
///
/// A note package is a directory:
///
/// ```
/// Biology.mbnote/
///   document.json            NoteManifest (this type)
///   ink/<page-id>.drawing    PencilKit drawing data for each page
///   recognition/<page-id>.json  handwriting recognition results
///   media/                   inserted images
///   sources/                 imported PDFs that pages draw on top of
///   recordings/<id>.m4a      audio, with <id>.json transcripts
///   thumbnail.png            first page preview for file browsers
/// ```
///
/// See docs/FORMAT.md for the full specification.
public struct NoteManifest: Codable, Hashable, Sendable {
    public static let currentFormat = "mbnotes.note/1"

    public var format: String
    public var id: UUID
    public var title: String
    public var kind: NoteKind
    public var createdAt: Date
    public var modifiedAt: Date
    /// Hex color that tints the cover and any template layer using the `accent` color token.
    public var accentColor: String
    public var cover: CoverSpec?
    public var defaultPaper: PaperRef
    public var pages: [PageSpec]
    public var tags: [String]
    public var recordings: [RecordingSummary]
    /// Snapshots of every template this note uses, so it renders the same on
    /// a device that does not have the pack installed.
    public var embedded: EmbeddedResources
    /// Free-form storage for tools and future features. Unknown keys are preserved.
    public var extensions: [String: JSONValue]

    public init(
        id: UUID = UUID(),
        title: String,
        kind: NoteKind,
        accentColor: String,
        cover: CoverSpec? = nil,
        defaultPaper: PaperRef,
        pages: [PageSpec] = [],
        tags: [String] = [],
        createdAt: Date = Date()
    ) {
        self.format = Self.currentFormat
        self.id = id
        self.title = title
        self.kind = kind
        self.createdAt = createdAt
        self.modifiedAt = createdAt
        self.accentColor = accentColor
        self.cover = cover
        self.defaultPaper = defaultPaper
        self.pages = pages
        self.tags = tags
        self.recordings = []
        self.embedded = EmbeddedResources()
        self.extensions = [:]
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(String.self, forKey: .format)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        kind = try c.decodeIfPresent(NoteKind.self, forKey: .kind) ?? .note
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? createdAt
        accentColor = try c.decodeIfPresent(String.self, forKey: .accentColor) ?? "#F76CA0"
        cover = try c.decodeIfPresent(CoverSpec.self, forKey: .cover)
        defaultPaper = try c.decodeIfPresent(PaperRef.self, forKey: .defaultPaper) ?? PaperRef(template: .blankPaper)
        pages = try c.decodeIfPresent([PageSpec].self, forKey: .pages) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        recordings = try c.decodeIfPresent([RecordingSummary].self, forKey: .recordings) ?? []
        embedded = try c.decodeIfPresent(EmbeddedResources.self, forKey: .embedded) ?? EmbeddedResources()
        extensions = try c.decodeIfPresent([String: JSONValue].self, forKey: .extensions) ?? [:]
    }
}

public enum NoteKind: String, Codable, Sendable, CaseIterable {
    /// Has a cover and usually a decorated title page.
    case notebook
    /// Plain pages, shown in the library by its first page.
    case note
    /// Created by importing a PDF, slide deck, or other document.
    case document
}

/// A reference to an item inside a content pack, written `pack-id/item-id`.
public struct ContentRef: Hashable, Codable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public var packID: String
    public var itemID: String

    public init(packID: String, itemID: String) {
        self.packID = packID
        self.itemID = itemID
    }

    public init?(rawValue: String) {
        guard let slash = rawValue.lastIndex(of: "/") else { return nil }
        let pack = String(rawValue[..<slash])
        let item = String(rawValue[rawValue.index(after: slash)...])
        guard !pack.isEmpty, !item.isEmpty else { return nil }
        self.init(packID: pack, itemID: item)
    }

    public init(stringLiteral value: String) {
        self = ContentRef(rawValue: value) ?? ContentRef(packID: CorePack.id, itemID: value)
    }

    public var rawValue: String { "\(packID)/\(itemID)" }
    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let ref = ContentRef(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Content references look like pack-id/item-id, got \(raw)"))
        }
        self = ref
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

public enum CorePack {
    public static let id = "com.marginallybetter.core"
}

public extension ContentRef {
    static let blankPaper = ContentRef(packID: CorePack.id, itemID: "blank")
}

/// Which paper template a page uses, plus per-page overrides.
public struct PaperRef: Codable, Hashable, Sendable {
    public var template: ContentRef
    /// Overrides the template's background color.
    public var background: String?
    /// Values for the template's declared parameters, such as line spacing.
    public var parameters: [String: Double]

    public init(template: ContentRef, background: String? = nil, parameters: [String: Double] = [:]) {
        self.template = template
        self.background = background
        self.parameters = parameters
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        template = try c.decode(ContentRef.self, forKey: .template)
        background = try c.decodeIfPresent(String.self, forKey: .background)
        parameters = try c.decodeIfPresent([String: Double].self, forKey: .parameters) ?? [:]
    }
}

public struct CoverSpec: Codable, Hashable, Sendable {
    public var design: ContentRef
    public var subtitle: String?
    public var stickers: [PlacedSticker]

    public init(design: ContentRef, subtitle: String? = nil, stickers: [PlacedSticker] = []) {
        self.design = design
        self.subtitle = subtitle
        self.stickers = stickers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        design = try c.decode(ContentRef.self, forKey: .design)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        stickers = try c.decodeIfPresent([PlacedSticker].self, forKey: .stickers) ?? []
    }
}

/// A sticker placed on a cover or folder, in unit coordinates (0...1) of its container.
public struct PlacedSticker: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var sticker: ContentRef
    public var x: Double
    public var y: Double
    public var scale: Double
    public var rotation: Double

    public init(id: UUID = UUID(), sticker: ContentRef, x: Double, y: Double, scale: Double = 1, rotation: Double = 0) {
        self.id = id
        self.sticker = sticker
        self.x = x
        self.y = y
        self.scale = scale
        self.rotation = rotation
    }
}

public struct PageSize: Codable, Hashable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public static let letter = PageSize(width: 612, height: 792)
    public static let a4 = PageSize(width: 595, height: 842)
    public static let a5 = PageSize(width: 420, height: 595)
    public static let widescreen = PageSize(width: 960, height: 540)

    public var landscape: PageSize { PageSize(width: max(width, height), height: min(width, height)) }
    public var portrait: PageSize { PageSize(width: min(width, height), height: max(width, height)) }
}

public struct PageSpec: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var size: PageSize
    public var paper: PaperRef
    /// A page of an imported document drawn beneath the paper's layers.
    public var source: PageSource?
    public var elements: [PageElement]
    public var createdAt: Date

    public init(id: UUID = UUID(), size: PageSize, paper: PaperRef, source: PageSource? = nil, elements: [PageElement] = [], createdAt: Date = Date()) {
        self.id = id
        self.size = size
        self.paper = paper
        self.source = source
        self.elements = elements
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        size = try c.decodeIfPresent(PageSize.self, forKey: .size) ?? .letter
        paper = try c.decodeIfPresent(PaperRef.self, forKey: .paper) ?? PaperRef(template: .blankPaper)
        source = try c.decodeIfPresent(PageSource.self, forKey: .source)
        elements = try c.decodeIfPresent([PageElement].self, forKey: .elements) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

public struct PageSource: Codable, Hashable, Sendable {
    /// Path inside the package, such as `sources/lecture-3.pdf`.
    public var file: String
    /// Zero-based page index in that PDF.
    public var pageIndex: Int

    public init(file: String, pageIndex: Int) {
        self.file = file
        self.pageIndex = pageIndex
    }
}

/// Typed text, a sticker, or an image placed on a page. Frames are in page points
/// with the origin at the top-left corner.
public struct PageElement: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case text, sticker, image
    }

    public var id: UUID
    public var kind: Kind
    public var frame: Rect
    public var rotation: Double
    public var text: TextContent?
    public var sticker: ContentRef?
    /// Path inside the package for `.image`, such as `media/<uuid>.png`.
    public var image: String?

    public init(id: UUID = UUID(), kind: Kind, frame: Rect, rotation: Double = 0, text: TextContent? = nil, sticker: ContentRef? = nil, image: String? = nil) {
        self.id = id
        self.kind = kind
        self.frame = frame
        self.rotation = rotation
        self.text = text
        self.sticker = sticker
        self.image = image
    }

    public static func text(_ string: String, frame: Rect, style: TextContent = TextContent()) -> PageElement {
        var content = style
        content.string = string
        return PageElement(kind: .text, frame: frame, text: content)
    }
}

public struct TextContent: Codable, Hashable, Sendable {
    public var string: String
    public var fontName: String?
    public var fontSize: Double
    public var color: String
    public var alignment: String

    public init(string: String = "", fontName: String? = nil, fontSize: Double = 17, color: String = "#1C1B2E", alignment: String = "left") {
        self.string = string
        self.fontName = fontName
        self.fontSize = fontSize
        self.color = color
        self.alignment = alignment
    }
}

public struct Rect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct RecordingSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var startedAt: Date
    public var duration: Double

    public init(id: UUID = UUID(), title: String, startedAt: Date, duration: Double) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.duration = duration
    }

    public var audioPath: String { "recordings/\(id.uuidString).m4a" }
    public var transcriptPath: String { "recordings/\(id.uuidString).json" }
    public var enhancedAudioPath: String { "recordings/\(id.uuidString).clear.m4a" }
}

public struct EmbeddedResources: Codable, Hashable, Sendable {
    public var papers: [String: PaperTemplate]
    public var covers: [String: CoverDesign]
    public var stickers: [String: StickerDefinition]

    public init(papers: [String: PaperTemplate] = [:], covers: [String: CoverDesign] = [:], stickers: [String: StickerDefinition] = [:]) {
        self.papers = papers
        self.covers = covers
        self.stickers = stickers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        papers = try c.decodeIfPresent([String: PaperTemplate].self, forKey: .papers) ?? [:]
        covers = try c.decodeIfPresent([String: CoverDesign].self, forKey: .covers) ?? [:]
        stickers = try c.decodeIfPresent([String: StickerDefinition].self, forKey: .stickers) ?? [:]
    }
}
