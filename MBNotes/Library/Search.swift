import NoteEngine
import SwiftUI

struct SearchResult: Identifiable, Hashable {
    let url: URL
    let title: String
    let snippet: String
    let source: String

    var id: String { url.path + source + snippet }
}

/// Searches titles, typed text, recognized handwriting, and transcripts.
enum SearchIndex {
    static func search(_ query: String, in library: LibraryStore) async -> [SearchResult] {
        await Task.detached(priority: .userInitiated) {
            let needle = query.trimmingCharacters(in: .whitespaces)
            guard !needle.isEmpty else { return [] }
            var results: [SearchResult] = []
            for item in library.allNotes() {
                guard let manifest = item.manifest else { continue }
                let package = NotePackage(url: item.url)
                if manifest.title.localizedCaseInsensitiveContains(needle) || manifest.tags.contains(where: { $0.localizedCaseInsensitiveContains(needle) }) {
                    results.append(SearchResult(url: item.url, title: item.name, snippet: manifest.tags.joined(separator: ", "), source: "Title"))
                }
                for page in manifest.pages {
                    for element in page.elements {
                        if let text = element.text?.string, let snippet = snippet(text, needle) {
                            results.append(SearchResult(url: item.url, title: item.name, snippet: snippet, source: "Typed text"))
                        }
                    }
                    if let text = package.readRecognition(for: page.id)?.text, let snippet = snippet(text, needle) {
                        results.append(SearchResult(url: item.url, title: item.name, snippet: snippet, source: "Handwriting"))
                    }
                }
                for recording in manifest.recordings {
                    if let text = package.readTranscript(recording)?.visibleText(labelSpeakers: false), let snippet = snippet(text, needle) {
                        results.append(SearchResult(url: item.url, title: item.name, snippet: snippet, source: "Recording"))
                    }
                }
                if results.count > 200 { break }
            }
            return results
        }.value
    }

    static func snippet(_ text: String, _ needle: String) -> String? {
        guard let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let start = text.index(range.lowerBound, offsetBy: -50, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 70, limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "…" : "") + text[start..<end].replacingOccurrences(of: "\n", with: " ") + (end < text.endIndex ? "…" : "")
    }
}

struct SearchResultsList: View {
    let results: [SearchResult]
    @Environment(AppModel.self) private var app

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            if results.isEmpty {
                ContentUnavailableView.search
            }
            ForEach(results) { result in
                Button {
                    app.openNote = .init(package: NotePackage(url: result.url))
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(result.title).font(.headline)
                            Spacer()
                            Text(result.source)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Brand.pink.opacity(0.15), in: .capsule)
                        }
                        if !result.snippet.isEmpty {
                            Text(result.snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(.regular, in: .rect(cornerRadius: 16))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
