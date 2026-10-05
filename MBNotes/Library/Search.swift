import NoteEngine
import SwiftUI

/// One note's search matches, grouped so a note appears once however many pages hit.
struct SearchResult: Identifiable, Hashable {
    struct Match: Hashable {
        let snippet: String
        let source: String
        let pageID: UUID?
    }

    let url: URL
    let title: String
    let modifiedAt: Date
    let matches: [Match]

    var id: URL { url }
    var best: Match? { matches.first }
}

enum SearchScope: String, CaseIterable, Identifiable {
    case all, folder
    var id: String { rawValue }
    var title: String { self == .all ? "All Notes" : "This Folder" }
}

/// Searches titles, tags, typed text, recognized handwriting, imported document text,
/// transcripts, and folder names.
enum SearchIndex {
    static func search(_ query: String, in library: LibraryStore, folder: URL? = nil) async throws -> [SearchResult] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        let notes = folder.map { library.contents(of: $0).filter { !$0.isFolder } } ?? library.allNotes()
        var results: [SearchResult] = []
        for item in notes {
            try Task.checkCancellation()
            guard let manifest = item.manifest else { continue }
            let package = NotePackage(url: item.url)
            var matches: [SearchResult.Match] = []
            if manifest.title.localizedCaseInsensitiveContains(needle) {
                matches.append(.init(snippet: "", source: "Title", pageID: nil))
            }
            if manifest.tags.contains(where: { $0.localizedCaseInsensitiveContains(needle) }) {
                matches.append(.init(snippet: manifest.tags.joined(separator: ", "), source: "Tags", pageID: nil))
            }
            for page in manifest.pages {
                for element in page.elements {
                    if let text = element.text?.string, let snippet = snippet(text, needle) {
                        matches.append(.init(snippet: snippet, source: "Typed", pageID: page.id))
                    }
                }
                if let text = package.readRecognition(for: page.id)?.text, let snippet = snippet(text, needle) {
                    matches.append(.init(snippet: snippet, source: "Handwriting", pageID: page.id))
                }
                if let source = page.source, let url = package.fileURL(source.file), let text = SourceText.text(of: url, page: source.pageIndex), let snippet = snippet(text, needle) {
                    matches.append(.init(snippet: snippet, source: "Document", pageID: page.id))
                }
            }
            for recording in manifest.recordings {
                if let text = package.readTranscript(recording)?.visibleText(labelSpeakers: false), let snippet = snippet(text, needle) {
                    matches.append(.init(snippet: snippet, source: "Recording", pageID: nil))
                }
            }
            if !matches.isEmpty {
                results.append(SearchResult(url: item.url, title: item.name, modifiedAt: item.modifiedAt, matches: matches))
            }
            if results.count > 200 { break }
        }
        return results
    }

    static func snippet(_ text: String, _ needle: String) -> String? {
        guard let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let start = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 80, limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "…" : "") + text[start..<end].replacingOccurrences(of: "\n", with: " ") + (end < text.endIndex ? "…" : "")
    }

    /// Bolds the query inside a snippet.
    static func highlighted(_ snippet: String, query: String) -> AttributedString {
        var text = AttributedString(snippet)
        if let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[range].font = .subheadline.bold()
            text[range].foregroundColor = .primary
        }
        return text
    }
}

struct SearchResultsList: View {
    let results: [SearchResult]
    let query: String
    @Environment(SceneModel.self) private var scene

    var body: some View {
        List {
            if results.isEmpty {
                ContentUnavailableView.search(text: query)
            }
            ForEach(results) { result in
                Button {
                    scene.open(result.url, pageID: result.best?.pageID)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(result.title).font(.body).lineLimit(1)
                        HStack(spacing: 6) {
                            Text(result.modifiedAt.libraryDescription)
                            if let best = result.best {
                                if best.snippet.isEmpty {
                                    Text(best.source)
                                } else {
                                    Text(SearchIndex.highlighted(best.snippet, query: query)).lineLimit(2)
                                }
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        if result.matches.count > 1 {
                            Text("\(result.matches.count) matches").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}
