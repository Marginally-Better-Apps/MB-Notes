import Foundation

/// Any JSON value. Used where the format promises to round-trip data it does not understand.
public enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }
}

/// Folder appearance, stored as `.folder.json` inside the folder's directory.
public struct FolderMetadata: Codable, Hashable, Sendable {
    public static let fileName = ".folder.json"
    public static let currentFormat = "mbnotes.folder/1"

    public var format: String
    public var id: UUID
    public var color: String
    public var symbol: String
    public var stickers: [PlacedSticker]
    public var createdAt: Date

    public init(id: UUID = UUID(), color: String, symbol: String, stickers: [PlacedSticker] = [], createdAt: Date = Date()) {
        self.format = Self.currentFormat
        self.id = id
        self.color = color
        self.symbol = symbol
        self.stickers = stickers
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? Self.currentFormat
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "#8056F6"
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "folder.fill"
        stickers = try c.decodeIfPresent([PlacedSticker].self, forKey: .stickers) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

/// Handwriting and printed text found on a page, stored as `recognition/<page-id>.json`.
public struct PageRecognition: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public struct Line: Codable, Hashable, Sendable {
        public var text: String
        public var confidence: Double
        /// Page points, top-left origin.
        public var box: Rect

        public init(text: String, confidence: Double, box: Rect) {
            self.text = text
            self.confidence = confidence
            self.box = box
        }
    }

    public var version: Int
    /// Fingerprint of the ink that was recognized, so stale results can be detected.
    public var inkFingerprint: String
    public var lines: [Line]
    public var recognizedAt: Date

    public init(inkFingerprint: String, lines: [Line], recognizedAt: Date = Date()) {
        self.version = Self.currentVersion
        self.inkFingerprint = inkFingerprint
        self.lines = lines
        self.recognizedAt = recognizedAt
    }

    public var text: String { lines.map(\.text).joined(separator: "\n") }
}

/// A recording's transcript, speakers, and analysis, stored as `recordings/<id>.json`.
public struct Transcript: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public struct Word: Codable, Hashable, Sendable {
        public var text: String
        public var start: Double
        public var end: Double

        public init(text: String, start: Double, end: Double) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    public struct Segment: Codable, Hashable, Sendable, Identifiable {
        public var id: UUID
        public var start: Double
        public var end: Double
        public var text: String
        public var speaker: String?
        public var words: [Word]

        public init(id: UUID = UUID(), start: Double, end: Double, text: String, speaker: String? = nil, words: [Word] = []) {
            self.id = id
            self.start = start
            self.end = end
            self.text = text
            self.speaker = speaker
            self.words = words
        }
    }

    public struct Speaker: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var color: String

        public init(id: String, name: String, color: String) {
            self.id = id
            self.name = name
            self.color = color
        }
    }

    public struct Span: Codable, Hashable, Sendable {
        public var start: Double
        public var end: Double

        public init(start: Double, end: Double) {
            self.start = start
            self.end = end
        }
    }

    public var version: Int
    public var recordingID: UUID
    public var startedAt: Date
    public var duration: Double
    public var locale: String
    /// Which engine produced `segments`, such as `apple.speech` or `desertant.voz`.
    public var engine: String
    public var segments: [Segment]
    public var speakers: [Speaker]
    /// Speakers the user chose to hide from the transcript and from AI features.
    public var hiddenSpeakers: [String]
    public var fillers: [Span]
    public var summary: String?
    /// True once on-device post-processing (diarization, filler detection) has run.
    public var isProcessed: Bool

    public init(recordingID: UUID, startedAt: Date, duration: Double = 0, locale: String, engine: String) {
        self.version = Self.currentVersion
        self.recordingID = recordingID
        self.startedAt = startedAt
        self.duration = duration
        self.locale = locale
        self.engine = engine
        self.segments = []
        self.speakers = []
        self.hiddenSpeakers = []
        self.fillers = []
        self.summary = nil
        self.isProcessed = false
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        recordingID = try c.decode(UUID.self, forKey: .recordingID)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        locale = try c.decodeIfPresent(String.self, forKey: .locale) ?? "en-US"
        engine = try c.decodeIfPresent(String.self, forKey: .engine) ?? "unknown"
        segments = try c.decodeIfPresent([Segment].self, forKey: .segments) ?? []
        speakers = try c.decodeIfPresent([Speaker].self, forKey: .speakers) ?? []
        hiddenSpeakers = try c.decodeIfPresent([String].self, forKey: .hiddenSpeakers) ?? []
        fillers = try c.decodeIfPresent([Span].self, forKey: .fillers) ?? []
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        isProcessed = try c.decodeIfPresent(Bool.self, forKey: .isProcessed) ?? false
    }

    /// Transcript text with hidden speakers removed, labeled by speaker name when known.
    public func visibleText(labelSpeakers: Bool = true) -> String {
        let names = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.name) })
        return segments
            .filter { segment in segment.speaker.map { !hiddenSpeakers.contains($0) } ?? true }
            .map { segment in
                if labelSpeakers, let speaker = segment.speaker, let name = names[speaker] {
                    return "\(name): \(segment.text)"
                }
                return segment.text
            }
            .joined(separator: "\n")
    }
}

public enum NoteJSON {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var c = encoder.singleValueContainer()
            try c.encode(formatter.string(from: date))
        }
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let seconds = try? c.decode(Double.self) { return Date(timeIntervalSince1970: seconds) }
            let string = try c.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = ISO8601DateFormatter().date(from: string) ?? fractional.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Expected an ISO 8601 date, got \(string)")
        }
        return d
    }()
}
