import XCTest
import Vision

final class CollaborationInteractionTests: XCTestCase {
    private func launch(keep: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-collaborationTesting", "-ApplePersistenceIgnoreState", "YES", "-appearance", "light"]
        if keep { app.launchArguments += ["-collaborationKeepLibrary"] }
        app.launch()
        let note = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Collaboration fixture, note")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 30), app.debugDescription)
        note.tap()
        XCTAssertTrue(app.buttons["editor-live-collaboration"].waitForExistence(timeout: 30), app.debugDescription)
        // The note's presentation animation can expose its toolbar before it accepts taps.
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: app.buttons["editor-live-collaboration"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        Thread.sleep(forTimeInterval: 1)
        return app
    }
    private func host(_ app: XCUIApplication) {
        app.buttons["editor-live-collaboration"].tap()
        let pen = app.webViews.switches["Pen"]
        XCTAssertTrue(pen.waitForExistence(timeout: 45), app.debugDescription)
        XCTAssertTrue(pen.isEnabled)
        // Dismiss Local Network authorization if this fresh simulator presents it.
        if app.alerts.buttons["Allow"].exists { app.alerts.buttons["Allow"].tap() }
    }
    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testHostTextInkLaserInvitationAndSavedNoteAfterRestart() throws {
        let app = launch(); host(app)
        let paper = app.webViews.images["Shared canvas"]
        XCTAssertTrue(paper.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertGreaterThan(paper.frame.width, 300)
        XCTAssertGreaterThan(paper.frame.height, 300)
        XCTAssertEqual(paper.frame.width / paper.frame.height, 612.0 / 792.0, accuracy: 0.02, "Imported paper must retain its aspect ratio")
        XCTAssertTrue(app.frame.contains(paper.frame), "The paper must fit inside the viewport")
        app.webViews.switches["Add text"].tap()
        paper.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).tap()
        let text = app.webViews.textViews["Text to add"]
        XCTAssertTrue(text.waitForExistence(timeout: 5), app.debugDescription)
        text.tap(); text.typeText("Saved collaboration text")
        app.webViews.buttons["Add to canvas"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.webViews.staticTexts["Revision 1"].waitForExistence(timeout: 10))
        app.webViews.switches["Pen"].tap()
        paper.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).press(forDuration: 0.05, thenDragTo: paper.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.55)))
        XCTAssertTrue(app.webViews.staticTexts["Revision 2"].waitForExistence(timeout: 10), app.debugDescription)
        app.webViews.switches["Laser pointer"].tap()
        paper.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.6)).press(forDuration: 0.1, thenDragTo: paper.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6)))
        XCTAssertTrue(app.webViews.staticTexts["Revision 2"].exists)
        capture("Native laser without a saved ink change", app)
        app.webViews.buttons["Invite"].tap()
        XCTAssertTrue(app.webViews.images["Session invitation QR code"].waitForExistence(timeout: 5))
        let link = app.webViews.textFields["Session link"].value as? String ?? ""
        XCTAssertTrue(link.hasPrefix("https://planista.shloklab.us/"), "The native invitation must use the published web client")
        capture("Native host with invitation QR", app)
        app.webViews.buttons["Close invitation"].tap()
        capture("Native shared paper after text and ink", app)
        app.buttons["Done"].tap()
        try assertSavedPaper(app)
        app.terminate()
        let reopened = launch(keep: true)
        reopened.buttons["View"].tap()
        try assertSavedPaper(reopened)
        host(reopened)
        // A new session starts from the saved paper, rather than keeping old overlays.
        XCTAssertTrue(reopened.webViews.staticTexts["Revision 0"].waitForExistence(timeout: 10))
        capture("Saved paper in a fresh session", reopened)
        reopened.buttons["Done"].tap()
    }
    func testNativeJoinFormRejectsInvalidInvitation() {
        let app = XCUIApplication()
        app.launchArguments = ["-collaborationTesting", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        let more = app.buttons["library-more"]
        XCTAssertTrue(more.waitForExistence(timeout: 30)); more.tap()
        app.buttons["Join Live Note"].tap()
        let field = app.descendants(matching: .any).matching(identifier: "collaboration-invitation").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        field.tap(); field.typeText("invalid invitation")
        app.buttons["Join session"].tap()
        XCTAssertTrue(app.alerts.staticTexts["This is not a valid MB Notes session invitation."].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        capture("Join invitation validation", app)
        app.buttons["Done"].tap()
    }
    func testNativeQRScannerReportsUnavailableCameraAndReturnsToJoinForm() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-collaborationTesting", "-ApplePersistenceIgnoreState", "YES"]
        let monitor = addUIInterruptionMonitor(withDescription: "Camera authorization") { alert in
            let deny = alert.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Allow")).firstMatch
            if deny.exists { deny.tap(); return true }
            return false
        }
        defer { removeUIInterruptionMonitor(monitor) }
        app.launch()
        let more = app.buttons["library-more"]
        XCTAssertTrue(more.waitForExistence(timeout: 30)); more.tap(); app.buttons["Join Live Note"].tap()
        app.buttons["Scan QR code"].tap()
        app.tap()
        let unavailable = app.staticTexts["Camera unavailable. Paste the invitation link instead."]
        XCTAssertTrue(unavailable.waitForExistence(timeout: 10), app.debugDescription)
        capture("QR scanner without camera hardware", app)
        app.buttons["cancel-collaboration-scan"].tap()
        XCTAssertTrue(app.buttons["Join session"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
    }

    private func assertSavedPaper(_ app: XCUIApplication) throws {
        // PencilKit owns this accessibility container. Check the rendered paper itself.
        let deadline = Date().addingTimeInterval(10)
        var recognized = "", pixels: CGImage?
        repeat {
            let image = try XCTUnwrap(app.screenshot().image.cgImage)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: image).perform([request])
            recognized = request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
            pixels = image
            if recognized.contains("Saved collaboration text") { break }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        XCTAssertTrue(recognized.contains("Saved collaboration text"), "Saved text missing from the rendered native page: \(recognized)")
        let image = try XCTUnwrap(pixels), width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let inkPixels = bytes.withUnsafeMutableBytes { buffer -> Int in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return 0 }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let data = buffer.bindMemory(to: UInt8.self)
            var count = 0
            // Exclude toolbar controls; the fixture has no preexisting indigo ink.
            for y in (height * 35 / 100)..<(height * 75 / 100) {
                for x in (width * 15 / 100)..<(width * 85 / 100) {
                    let index = (y * width + x) * 4
                    let red = Int(data[index]), green = Int(data[index + 1]), blue = Int(data[index + 2])
                    if blue > 130 && blue > red * 18 / 10 && blue > green * 2 { count += 1 }
                }
            }
            return count
        }
        XCTAssertGreaterThan(inkPixels, 50, "Saved PencilKit stroke missing from the native paper")
        capture("Saved text and ink on native paper", app)
    }

    private func ownerState() throws -> [String: Any] {
        let received = expectation(description: "Owner's saved note state")
        var response: Data?, failure: Error?
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:8765/fixture")!) { data, _, error in
            response = data; failure = error; received.fulfill()
        }.resume()
        wait(for: [received], timeout: 10)
        if let failure { throw failure }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(response)) as? [String: Any])
    }
    func testNativeGuestJoinsByAppLinkAndEditsTheOtherIOSOwnersNote() throws {
        continueAfterFailure = false
        let fixture = try ownerState(), invitation = try XCTUnwrap(fixture["invite"] as? [String: Any])
        let data = try JSONSerialization.data(withJSONObject: invitation)
        var components = URLComponents(string: "mbnotes://collaboration")!
        components.queryItems = [URLQueryItem(name: "invitation", value: String(decoding: data, as: UTF8.self))]
        let app = launch()
        app.open(try XCTUnwrap(components.url))
        let pen = app.webViews.switches["Pen"]
        XCTAssertTrue(pen.waitForExistence(timeout: 45), app.debugDescription)
        let connected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: pen)
        XCTAssertEqual(XCTWaiter.wait(for: [connected], timeout: 45), .completed)
        XCTAssertTrue(app.webViews.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Joined session")).firstMatch.exists)
        let paper = app.webViews.images["Shared canvas"]
        XCTAssertTrue(paper.exists)
        XCTAssertGreaterThan(paper.frame.width, 300, "A guest needs a usable page, rather than a reduced form sheet")
        XCTAssertGreaterThan(paper.frame.height, 300)
        XCTAssertEqual(paper.frame.width / paper.frame.height, 612.0 / 792.0, accuracy: 0.02)
        XCTAssertTrue(app.frame.contains(paper.frame))
        app.webViews.switches["Add text"].tap()
        paper.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.35)).tap()
        let text = app.webViews.textViews["Text to add"]
        XCTAssertTrue(text.waitForExistence(timeout: 5)); text.tap(); text.typeText("Native guest writes to the owner")
        app.webViews.buttons["Add to canvas"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.webViews.staticTexts["Revision 1"].waitForExistence(timeout: 10))
        pen.tap()
        paper.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6)).press(forDuration: 0.05, thenDragTo: paper.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.65)))
        XCTAssertTrue(app.webViews.staticTexts["Revision 2"].waitForExistence(timeout: 10))
        app.webViews.switches["Laser pointer"].tap()
        paper.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).press(forDuration: 0.1, thenDragTo: paper.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)))
        XCTAssertTrue(app.webViews.staticTexts["Revision 2"].exists)
        capture("Two iOS app instances share an imported page", app)
        // This status comes from the other app after its native note writer succeeds.
        var saved = try ownerState()
        for _ in 0..<5 where (saved["strokes"] as? Int ?? 0) == 0 { saved = try ownerState() }
        XCTAssertTrue((saved["texts"] as? [String])?.contains("Native guest writes to the owner") == true)
        XCTAssertEqual(saved["strokes"] as? Int, 1, "Laser movement must not create saved ink")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["library-more"].waitForExistence(timeout: 10))
    }

}
