import NoteEngine
import Observation
import PencilKit
import SwiftUI
import UIKit
import WebKit

@MainActor @Observable
final class CollaborationClient {
    let model: EditorModel?
    var invitation: CollaborationInvitation?
    var didJoin = false
    var status = "Starting…"
    var error: String?
    weak var controller: CollaborationWebController?
    private weak var suspendedCanvas: NoteCanvasController?
    private var baseline: NoteManifest?
    private var baselineInk: [UUID: PKDrawing] = [:]
    private var stopped = false
    private var prepared = false
    private var applied = Set<String>()
    private var strokeIDs: [String: (pageID: UUID, index: Int)] = [:]

    init(model: EditorModel? = nil, invitation: String? = nil) {
        self.model = model
        if model == nil, let invitation { join(invitation) }
    }
    func prepareHost() {
        guard !stopped, invitation == nil, let model else { return }
        model.canvas?.view.endEditing(true)
        model.canvas?.flushInk()
        model.save()
        guard model.errorMessage == nil else { error = model.errorMessage; return }
        suspendedCanvas = model.canvas
        prepared = true
        model.mode = .view
        model.canvas = nil
        baseline = model.manifest; baselineInk = model.drawings
        invitation = CollaborationInvitation(documentID: model.manifest.id, pageID: model.manifest.pages[safe: model.currentPageIndex]?.id)
    }
    func join(_ raw: String) {
        do { invitation = try CollaborationInvitation.parse(raw); didJoin = true; error = nil }
        catch { self.error = "This is not a valid MB Notes session invitation." }
    }
    func bootstrap() -> [String: Any] {
        guard let model, let invitation else { return [:] }
        let pages = model.manifest.pages.map { ["id": $0.id.uuidString.lowercased(), "width": $0.size.width, "height": $0.size.height] as [String: Any] }
        let config = Bundle.main.url(forResource: "Collaboration", withExtension: "json").flatMap { try? Data(contentsOf: $0) }
        let publicURL = config.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }?["publicURL"] ?? ""
        return ["document": ["id": model.manifest.id.uuidString.lowercased(), "title": model.manifest.title, "pages": pages, "objects": [], "revision": 0],
                "invite": invitation.dictionary, "publicURL": publicURL]
    }
    func background(_ pageID: String) -> String? {
        guard let model, let baseline, let id = UUID(uuidString: pageID), let page = baseline.pages.first(where: { $0.id == id }) else { return nil }
        let renderer = PageRenderer(package: model.package, manifest: baseline, catalog: model.catalog)
        guard let data = renderer.image(for: page, width: 1200, ink: baselineInk[id]).jpegData(compressionQuality: 0.8) else { return nil }
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }
    func persist(_ mutation: [String: Any]) throws {
        guard !stopped, let model else { throw CocoaError(.fileWriteUnknown) }
        let before = model.manifest, ink = model.drawings, strokes = strokeIDs
        model.undoManager.disableUndoRegistration()
        defer { model.undoManager.enableUndoRegistration() }
        do { try applyMutation(mutation) }
        catch {
            model.manifest = before; model.replaceInk(ink); strokeIDs = strokes
            // Best-effort rollback of any page files saved before a later write failed.
            model.save()
            throw error
        }
    }
    private func applyMutation(_ mutation: [String: Any]) throws {
        guard let model, let id = mutation["id"] as? String else { throw CocoaError(.fileWriteUnknown) }
        guard !applied.contains(id) else { return }
        if mutation["kind"] as? String == "add", let object = mutation["object"] as? [String: Any],
           let pageString = object["pageID"] as? String, let pageID = UUID(uuidString: pageString),
           let index = model.manifest.pages.firstIndex(where: { $0.id == pageID }), let objectID = UUID(uuidString: id) {
            if object["kind"] as? String == "text", let text = object["text"] as? String {
                let x = object["x"] as? Double ?? 0, y = object["y"] as? Double ?? 0, width = object["width"] as? Double ?? 300
                let fontSize = object["fontSize"] as? Double ?? 18
                let style = TextContent(fontSize: fontSize, color: object["color"] as? String ?? "#29243D")
                let attributes = PageRenderer.attributedString(for: TextContent(string: text, fontSize: fontSize, color: style.color))
                let height = attributes.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], context: nil).height + 8
                var element = PageElement.text(text, frame: Rect(x: x, y: y, width: width, height: max(34, height)), style: style)
                element.id = objectID
                model.addElement(element, toPage: index)
            } else if object["kind"] as? String == "stroke", let points = object["points"] as? [[String: Double]], points.count >= 2 {
                let width = object["width"] as? Double ?? 3
                let samples = points.enumerated().map { offset, point in
                    PKStrokePoint(location: CGPoint(x: point["x"] ?? 0, y: point["y"] ?? 0), timeOffset: Double(offset) * 0.01,
                                  size: CGSize(width: width, height: width), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
                }
                let color = UIColor(Color(hex: object["color"] as? String ?? "#4C3AD6"))
                let stroke = PKStroke(ink: PKInk(.pen, color: color), path: PKStrokePath(controlPoints: samples, creationDate: Date()))
                var drawings = model.drawings
                let old = drawings[pageID]?.strokes ?? []
                strokeIDs[id] = (pageID, old.count)
                drawings[pageID] = PKDrawing(strokes: old + [stroke])
                model.inkChanged(drawings)
            } else { throw CocoaError(.fileWriteUnknown) }
        } else if mutation["kind"] as? String == "remove", let objectID = mutation["objectID"] as? String {
            if let stroke = strokeIDs.removeValue(forKey: objectID) {
                var drawings = model.drawings
                var strokes = drawings[stroke.pageID]?.strokes ?? []
                guard strokes.indices.contains(stroke.index) else { throw CocoaError(.fileWriteUnknown) }
                strokes.remove(at: stroke.index); drawings[stroke.pageID] = PKDrawing(strokes: strokes)
                for (key, value) in strokeIDs where value.pageID == stroke.pageID && value.index > stroke.index { strokeIDs[key] = (value.pageID, value.index - 1) }
                model.inkChanged(drawings)
            } else if let uuid = UUID(uuidString: objectID), let page = model.manifest.pages.first(where: { $0.elements.contains(where: { $0.id == uuid }) }) {
                model.removeElement(uuid, onPage: page.id)
            } else { throw CocoaError(.fileWriteUnknown) }
        } else { throw CocoaError(.fileWriteUnknown) }
        model.errorMessage = nil
        model.save()
        if let error = model.errorMessage { throw NSError(domain: "CollaborationSave", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
        applied.insert(id)
    }
    func stop() {
        guard !stopped else { return }; stopped = true
        controller?.stop()
        if let model, prepared {
            model.save()
            model.canvas = suspendedCanvas
            model.collaborationDidEnd()
            suspendedCanvas = nil
        }
    }
}

final class CollaborationWebController: UIViewController, WKScriptMessageHandler {
    let client: CollaborationClient
    private let nearby = NearbyTransport()
    private(set) var webView: WKWebView!
    init(client: CollaborationClient) { self.client = client; super.init(nibName: nil, bundle: nil); client.controller = self }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidLoad() {
        super.viewDidLoad()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "collaboration")
        webView = WKWebView(frame: view.bounds, configuration: configuration)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.isInspectable = true
        webView.accessibilityIdentifier = "collaboration-web"
        view.addSubview(webView)
        nearby.opened = { [weak self] id in self?.call("opened", [id]) }
        nearby.received = { [weak self] id, message in self?.call("receive", [id, message]) }
        nearby.closed = { [weak self] id in self?.call("closed", [id]) }
        nearby.fallback = { [weak self] in self?.call("fallback", []) }
        nearby.status = { [weak self] value in self?.client.status = value }
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Collaboration") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else { client.error = "Build the React collaboration client before running the experiment." }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any], let type = payload["type"] as? String else { return }
        switch type {
        case "ready":
            guard let invitation = client.invitation else { return }
            if client.model != nil {
                do { try nearby.host(name: invitation.nearby); call("startHost", [client.bootstrap()]); reportFixture() }
                catch { client.error = error.localizedDescription }
            } else {
                call("startGuest", [invitation.dictionary]); nearby.join(name: invitation.nearby)
            }
        case "send": if let id = payload["id"] as? String, let body = payload["message"] as? [String: Any] { nearby.send(body, to: id) }
        case "close": if let id = payload["id"] as? String { nearby.close(id) }
        case "status": client.status = payload["value"] as? String ?? ""
        case "backgroundRequest":
            if let id = payload["pageID"] as? String, let image = client.background(id) { call("background", [id, image]) }
        case "persist":
            guard let mutation = payload["mutation"] as? [String: Any], let id = mutation["id"] as? String else { return }
            do { try client.persist(mutation); call("saved", [id]); reportFixture() }
            catch { client.error = error.localizedDescription; call("saved", [id, error.localizedDescription]) }
        case "stop": nearby.stop()
        default: break
        }
    }
    private func reportFixture() {
        guard Bundle.main.object(forInfoDictionaryKey: "MBNotesUIAutomation") as? String == "YES", ProcessInfo.processInfo.arguments.contains("-collaborationFixtureHost"), let model = client.model, let invitation = client.invitation else { return }
        let payload: [String: Any] = ["invite": invitation.dictionary, "texts": model.manifest.pages.flatMap { $0.elements.compactMap { $0.text?.string } }, "strokes": model.drawings.values.reduce(0) { $0 + $1.strokes.count }]
        if let data = try? JSONSerialization.data(withJSONObject: payload) { GalaReporter.send(kind: "fixture", body: data, type: "application/json") }
    }
    private func call(_ method: String, _ arguments: [Any]) {
        // JSON serializes every argument; user content is never interpolated into executable source.
        guard let data = try? JSONSerialization.data(withJSONObject: arguments), let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.mbNative?.\(method)(...\(json))") { [weak self] _, error in
            if let error { self?.client.error = error.localizedDescription }
            else if ["background", "saved"].contains(method), Bundle.main.object(forInfoDictionaryKey: "MBNotesUIAutomation") as? String == "YES" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { GalaReporter.screenshot() }
            }
        }
    }
    func stop() {
        nearby.stop()
        webView?.evaluateJavaScript("window.mbNative && window.dispatchEvent(new Event('mb-stop'))")
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "collaboration")
    }
}
