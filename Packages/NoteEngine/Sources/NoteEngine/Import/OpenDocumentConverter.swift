import Foundation
import ZIPFoundation

/// Converts OpenDocument files (ODT, ODP, ODS) into simple HTML.
///
/// ODF files are zip archives with the document body in `content.xml`. This
/// keeps the structure that matters for note-taking (headings, paragraphs,
/// emphasis, lists, tables, images, and one section per slide) and drops
/// detailed layout. The HTML is then paginated to PDF like any web page.
public enum OpenDocumentConverter {
    public struct Output {
        public let html: String
        /// Directory holding extracted images, usable as the HTML base URL.
        public let resourceDirectory: URL
        public let isPresentation: Bool
    }

    public enum ConversionError: LocalizedError {
        case missingContent

        public var errorDescription: String? { "This OpenDocument file has no readable content." }
    }

    public static func convert(_ url: URL) throws -> Output {
        let workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("odf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try FileManager.default.unzipItem(at: url, to: workDirectory)
        guard let content = try? Data(contentsOf: workDirectory.appendingPathComponent("content.xml")) else {
            throw ConversionError.missingContent
        }
        let builder = HTMLBuilder()
        let parser = XMLParser(data: content)
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        parser.parse()
        let isPresentation = ["odp", "otp"].contains(url.pathExtension.lowercased())
        let css = """
        body { font: 14px -apple-system, Helvetica, sans-serif; color: #1C1B2E; line-height: 1.45; }
        h1, h2, h3 { color: #2B2350; } table { border-collapse: collapse; margin: 8px 0; }
        td, th { border: 1px solid #C9C4DA; padding: 4px 6px; vertical-align: top; }
        img { max-width: 100%; } .slide { page-break-after: always; min-height: 90vh; padding: 12px 0; }
        """
        let html = "<!doctype html><html><head><meta charset=\"utf-8\"><style>\(css)</style></head><body>\(builder.html)</body></html>"
        return Output(html: html, resourceDirectory: workDirectory, isPresentation: isPresentation)
    }

    private final class HTMLBuilder: NSObject, XMLParserDelegate {
        var html = ""
        private var styles: [String: String] = [:]
        private var currentStyleName: String?
        private var inAutomaticStyles = false
        private var openTags: [String?] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch name {
            case "office:automatic-styles":
                inAutomaticStyles = true
                openTags.append(nil)
                return
            case "style:style" where inAutomaticStyles:
                currentStyleName = attributes["style:name"]
                openTags.append(nil)
                return
            case "style:text-properties" where inAutomaticStyles:
                var css: [String] = []
                if attributes["fo:font-weight"] == "bold" { css.append("font-weight:bold") }
                if attributes["fo:font-style"] == "italic" { css.append("font-style:italic") }
                if let underline = attributes["style:text-underline-style"], underline != "none" { css.append("text-decoration:underline") }
                if let color = attributes["fo:color"] { css.append("color:\(color)") }
                if let name = currentStyleName, !css.isEmpty { styles[name] = css.joined(separator: ";") }
                openTags.append(nil)
                return
            default:
                break
            }
            let style = attributes["text:style-name"].flatMap { styles[$0] }.map { " style=\"\($0)\"" } ?? ""
            var tag: String?
            switch name {
            case "text:h":
                let level = min(max(Int(attributes["text:outline-level"] ?? "1") ?? 1, 1), 6)
                tag = "h\(level)"
            case "text:p": tag = "p"
            case "text:span": tag = "span"
            case "text:a": tag = "a"
            case "text:list": tag = "ul"
            case "text:list-item": tag = "li"
            case "table:table":
                if let sheet = attributes["table:name"], !sheet.isEmpty { html += "<h3>\(escape(sheet))</h3>" }
                tag = "table"
            case "table:table-row": tag = "tr"
            case "table:table-cell", "table:covered-table-cell": tag = "td"
            case "draw:page": tag = "section class=\"slide\""
            case "text:line-break": html += "<br>"
            case "text:tab": html += "&emsp;"
            case "text:s":
                let count = Int(attributes["text:c"] ?? "1") ?? 1
                html += String(repeating: "&nbsp;", count: max(1, min(count, 40)))
            case "draw:image":
                if let href = attributes["xlink:href"], !href.hasPrefix("http") { html += "<img src=\"\(escape(href))\">" }
            default: break
            }
            if let tag {
                let open = tag.split(separator: " ").first.map(String.init) ?? tag
                html += tag.contains(" ") ? "<\(tag)>" : "<\(tag)\(style)>"
                openTags.append(open)
            } else {
                openTags.append(nil)
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "office:automatic-styles" { inAutomaticStyles = false }
            if name == "style:style" { currentStyleName = nil }
            guard let tag = openTags.popLast() else { return }
            if let tag { html += "</\(tag)>" }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard !inAutomaticStyles else { return }
            html += escape(string)
        }

        private func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
    }
}
