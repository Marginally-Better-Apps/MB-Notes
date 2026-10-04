#if canImport(UIKit) && canImport(WebKit)
import PDFKit
import UIKit
import UniformTypeIdentifiers
import WebKit

/// Turns outside documents into notes you can write on.
///
/// Everything is first converted to PDF, then each PDF page becomes a note page
/// that draws the original underneath your ink:
/// - PDF: used as is.
/// - Word, PowerPoint, Excel, Pages, Keynote, Numbers: rendered by WebKit's
///   built-in document viewer, then paginated.
/// - OpenDocument (ODT, ODP, ODS): converted to HTML, then paginated.
/// - Images: one page per image.
/// - RTF, plain text, Markdown, HTML: typeset and paginated.
public enum DocumentImporter {
    public enum Kind: Sendable {
        case pdf, office, openDocument, image, text, html
    }

    public enum ImportError: LocalizedError {
        case unsupported(String)
        case emptyResult(String)

        public var errorDescription: String? {
            switch self {
            case .unsupported(let name): return "MB Notes can't import \(name) yet."
            case .emptyResult(let name): return "\(name) didn't produce any pages."
            }
        }
    }

    public static let supportedTypes: [UTType] = {
        var types: [UTType] = [.pdf, .image, .rtf, .plainText, .html, .rtfd]
        let extensions = ["docx", "doc", "pptx", "ppt", "xlsx", "xls", "pages", "key", "numbers", "odt", "odp", "ods", "md", "markdown"]
        types += extensions.compactMap { UTType(filenameExtension: $0) }
        return types
    }()

    public static func kind(for url: URL) -> Kind? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf": return .pdf
        case "docx", "doc", "pptx", "ppt", "xlsx", "xls", "pages", "key", "numbers": return .office
        case "odt", "odp", "ods", "ott", "otp": return .openDocument
        case "rtf", "rtfd", "txt", "text", "md", "markdown": return .text
        case "html", "htm": return .html
        default:
            if let type = UTType(filenameExtension: ext), type.conforms(to: .image) { return .image }
            return nil
        }
    }

    private static func isPresentation(_ url: URL) -> Bool {
        ["pptx", "ppt", "key", "odp", "otp"].contains(url.pathExtension.lowercased())
    }

    /// Converts a supported file to a PDF in the temporary directory.
    @MainActor
    public static func convertToPDF(_ url: URL) async throws -> URL {
        guard let kind = kind(for: url) else { throw ImportError.unsupported(url.lastPathComponent) }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        let landscape = isPresentation(url)
        let paper = landscape ? CGSize(width: 792, height: 612) : CGSize(width: 612, height: 792)
        let data: Data
        switch kind {
        case .pdf:
            return url
        case .office:
            data = try await WebPDFConverter().convert(fileURL: url, paperSize: paper, margin: landscape ? 0 : 36)
        case .html:
            data = try await WebPDFConverter().convert(fileURL: url, paperSize: paper, margin: 36)
        case .openDocument:
            let converted = try OpenDocumentConverter.convert(url)
            data = try await WebPDFConverter().convert(html: converted.html, baseURL: converted.resourceDirectory, paperSize: paper, margin: 36)
        case .image:
            data = try imagesToPDF([url])
        case .text:
            data = try textToPDF(url, paperSize: paper)
        }
        guard !data.isEmpty else { throw ImportError.emptyResult(url.lastPathComponent) }
        try data.write(to: output, options: .atomic)
        return output
    }

    /// One page per image, each sized to the image's aspect ratio at letter width.
    public static func imagesToPDF(_ urls: [URL]) throws -> Data {
        let images = urls.compactMap { UIImage(contentsOfFile: $0.path) }
        guard let first = images.first else { throw ImportError.emptyResult(urls.first?.lastPathComponent ?? "image") }
        func size(for image: UIImage) -> CGSize {
            let width: CGFloat = 612
            return CGSize(width: width, height: width * image.size.height / max(image.size.width, 1))
        }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size(for: first)))
        return renderer.pdfData { context in
            for image in images {
                let bounds = CGRect(origin: .zero, size: size(for: image))
                context.beginPage(withBounds: bounds, pageInfo: [:])
                image.draw(in: bounds)
            }
        }
    }

    @MainActor
    static func textToPDF(_ url: URL, paperSize: CGSize) throws -> Data {
        let ext = url.pathExtension.lowercased()
        let text: NSAttributedString
        if ext == "rtf" || ext == "rtfd" {
            text = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        } else {
            let string = try String(contentsOf: url, encoding: .utf8)
            text = NSAttributedString(string: string, attributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor.black])
        }
        let formatter = UISimpleTextPrintFormatter(attributedText: text)
        return paginate(formatter: formatter, paperSize: paperSize, margin: 54)
    }

    @MainActor
    static func paginate(formatter: UIPrintFormatter, paperSize: CGSize, margin: CGFloat) -> Data {
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
        let paper = CGRect(origin: .zero, size: paperSize)
        renderer.setValue(NSValue(cgRect: paper), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: paper.insetBy(dx: margin, dy: margin)), forKey: "printableRect")
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, paper, nil)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
        for page in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: page, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }

    /// Creates a document note whose pages draw the PDF's pages.
    public static func createNote(fromPDF pdfURL: URL, title: String, accentColor: String, in folder: URL, library: LibraryStore, catalog: PackCatalog) throws -> NotePackage {
        guard let document = CGPDFDocument(pdfURL as CFURL), document.numberOfPages > 0 else {
            throw ImportError.emptyResult(title)
        }
        var manifest = NoteManifest(title: title, kind: .document, accentColor: accentColor, defaultPaper: PaperRef(template: .blankPaper))
        let package = try library.createNote(manifest, in: folder)
        let source = try package.importFile(pdfURL, into: "sources")
        manifest.pages = pages(for: document, source: source)
        NoteFactory.embedResources(in: &manifest, catalog: catalog)
        try package.writeManifest(manifest)
        return package
    }

    /// Appends a PDF's pages to an existing note, returning the new pages.
    public static func appendPDF(_ pdfURL: URL, to package: NotePackage, manifest: inout NoteManifest) throws -> [PageSpec] {
        guard let document = CGPDFDocument(pdfURL as CFURL), document.numberOfPages > 0 else {
            throw ImportError.emptyResult(pdfURL.lastPathComponent)
        }
        let source = try package.importFile(pdfURL, into: "sources")
        let newPages = pages(for: document, source: source)
        manifest.pages.append(contentsOf: newPages)
        return newPages
    }

    static func pages(for document: CGPDFDocument, source: String) -> [PageSpec] {
        (0..<document.numberOfPages).map { index in
            let page = document.page(at: index + 1)
            let box = page?.getBoxRect(.cropBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
            let rotated = (page?.rotationAngle ?? 0) % 180 != 0
            let size = rotated ? PageSize(width: box.height, height: box.width) : PageSize(width: box.width, height: box.height)
            return PageSpec(size: size, paper: PaperRef(template: .blankPaper), source: PageSource(file: source, pageIndex: index))
        }
    }
}

/// Loads a document in an offscreen web view and prints it to PDF.
@MainActor
final class WebPDFConverter: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var continuation: CheckedContinuation<Void, Error>?

    override init() {
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 816, height: 1056))
        super.init()
        webView.navigationDelegate = self
    }

    func convert(fileURL: URL, paperSize: CGSize, margin: CGFloat) async throws -> Data {
        try await load { $0.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent()) }
        return render(paperSize: paperSize, margin: margin)
    }

    func convert(html: String, baseURL: URL, paperSize: CGSize, margin: CGFloat) async throws -> Data {
        let file = baseURL.appendingPathComponent("index.html")
        try html.write(to: file, atomically: true, encoding: .utf8)
        try await load { $0.loadFileURL(file, allowingReadAccessTo: baseURL) }
        return render(paperSize: paperSize, margin: margin)
    }

    private func load(_ start: (WKWebView) -> Void) async throws {
        // Some document types only lay out inside a window, so attach invisibly while loading.
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        webView.alpha = 0.01
        window?.insertSubview(webView, at: 0)
        defer { webView.removeFromSuperview() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            start(webView)
        }
        // Give converted Office documents a moment to finish layout.
        try await Task.sleep(for: .milliseconds(600))
    }

    private func render(paperSize: CGSize, margin: CGFloat) -> Data {
        DocumentImporter.paginate(formatter: webView.viewPrintFormatter(), paperSize: paperSize, margin: margin)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
#endif
