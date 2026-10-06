import Foundation
import Network
import NoteEngine
import PencilKit
import Testing
import XCTest
@testable import MBNotes

@MainActor
final class NearbyTransportTests: XCTestCase {
    func testNineGuestsExchangeFramedMessagesOverTCP() throws {
        let owner = NearbyTransport()
        let ready = expectation(description: "listener ready")
        var endpoint: NWEndpoint?
        owner.listening = { port in endpoint = .hostPort(host: "127.0.0.1", port: port); ready.fulfill() }
        try owner.host(name: "test-" + UUID().uuidString, advertise: false)
        defer { owner.stop() }
        wait(for: [ready], timeout: 10)
        let connected = expectation(description: "nine guests connect"); connected.expectedFulfillmentCount = 9
        let received = expectation(description: "nine guest messages reach owner"); received.expectedFulfillmentCount = 9
        let replies = expectation(description: "nine owner replies reach guests"); replies.expectedFulfillmentCount = 9
        owner.opened = { _ in connected.fulfill() }
        owner.received = { id, message in
            XCTAssertEqual(message["type"] as? String, "probe")
            XCTAssertEqual(message["text"] as? String, "Long message " + String(repeating: "✍", count: 3000))
            received.fulfill(); owner.send(["type": "reply"], to: id)
        }
        let guests = (0..<9).map { _ in NearbyTransport() }
        defer { for guest in guests { guest.stop() } }
        for guest in guests {
            guest.opened = { id in guest.send(["type": "probe", "text": "Long message " + String(repeating: "✍", count: 3000)], to: id) }
            guest.received = { _, message in XCTAssertEqual(message["type"] as? String, "reply"); replies.fulfill() }
            guest.connect(to: try XCTUnwrap(endpoint))
        }
        wait(for: [connected, received, replies], timeout: 15)
    }
}

@MainActor @Suite
struct CollaborationPersistenceTests {
    @Test func sharedAdditionsSaveToNativeNoteAndUndoPreservesBaselineInk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("collaboration-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = PackRegistry(builtInDirectory: Bundle.main.url(forResource: "Packs", withExtension: nil), userDirectory: root.appendingPathComponent("packs"))
        let catalog = registry.reload()
        let manifest = NoteFactory.note(title: "Shared biology", accentColor: "#8056F6", paper: PaperRef(template: ContentRef(packID: CorePack.id, itemID: "lined")), size: .letter, catalog: catalog)
        let package = try LibraryStore(root: root).createNote(manifest, in: root)
        let model = try EditorModel(package: package, catalog: catalog)
        let pageID = manifest.pages[0].id
        let baselinePoints = [CGPoint(x: 30, y: 30), CGPoint(x: 80, y: 80)].enumerated().map { i,p in
            PKStrokePoint(location: p, timeOffset: Double(i) * 0.1, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let baseline = PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: baselinePoints, creationDate: Date()))
        model.inkChanged([pageID: PKDrawing(strokes: [baseline])]); model.save()
        let client = CollaborationClient(model: model)
        client.prepareHost()
        defer { client.stop() }
        let textID = UUID().uuidString.lowercased(), strokeID = UUID().uuidString.lowercased()
        try client.persist(["id": textID, "kind": "add", "object": ["kind": "text", "pageID": pageID.uuidString, "text": "Collaborative cells", "x": 100.0, "y": 120.0, "width": 200.0, "fontSize": 18.0, "color": "#4C3AD6"]])
        try client.persist(["id": strokeID, "kind": "add", "object": ["kind": "stroke", "pageID": pageID.uuidString, "points": [["x": 150.0, "y": 200.0], ["x": 250.0, "y": 240.0]], "width": 3.0, "color": "#4C3AD6"]])
        let saved = try EditorModel(package: package, catalog: catalog)
        #expect(saved.manifest.pages[0].elements.contains { $0.id == UUID(uuidString: textID) && $0.text?.string == "Collaborative cells" })
        #expect(saved.drawings[pageID]?.strokes.count == 2)
        #expect(client.background(pageID.uuidString)?.hasPrefix("data:image/jpeg;base64,") == true)
        try client.persist(["id": UUID().uuidString, "kind": "remove", "objectID": strokeID])
        #expect(model.drawings[pageID]?.strokes.count == 1)
        #expect(model.drawings[pageID]?.strokes.first?.path[0].location == baseline.path[0].location)
        let afterUndo = try EditorModel(package: package, catalog: catalog)
        #expect(afterUndo.drawings[pageID]?.strokes.count == 1)
        #expect(afterUndo.manifest.pages[0].elements.count == 1)
    }
    @Test func invitationsParseBrowserAndAppLinks() throws {
        let invitation = CollaborationInvitation(documentID: UUID())
        let data = try JSONEncoder().encode(invitation)
        let json = String(decoding: data, as: UTF8.self)
        var browser = URLComponents(string: "https://notes.example/demo")!
        var fragment = URLComponents(); fragment.queryItems = [URLQueryItem(name: "mb", value: json)]
        browser.percentEncodedFragment = fragment.percentEncodedQuery
        #expect(try CollaborationInvitation.parse(browser.url!.absoluteString).session == invitation.session)
        var app = URLComponents(string: "mbnotes://collaboration")!; app.queryItems = [URLQueryItem(name: "invitation", value: json)]
        #expect(try CollaborationInvitation.parse(app.url!.absoluteString).document == invitation.document)
    }
}
