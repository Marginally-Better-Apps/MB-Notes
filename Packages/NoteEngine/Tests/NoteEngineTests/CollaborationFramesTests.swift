import Foundation
import Testing
@testable import NoteEngine

struct CollaborationFramesTests {
    @Test func fragmentedAndCoalescedFrames() throws {
        let first = Data(#"{"type":"hello","token":"test"}"#.utf8)
        let second = Data(#"{"type":"edit","text":"unicode ✍️"}"#.utf8)
        let encoded = try CollaborationFrames.encode(first) + CollaborationFrames.encode(second)
        var decoder = CollaborationFrames()
        var result: [Data] = []
        for byte in encoded { result += try decoder.append(Data([byte])) }
        #expect(result == [first, second])
        #expect(try decoder.append(encoded) == [first, second])
    }
    @Test func rejectsOversizeAndInvalidJSON() throws {
        var decoder = CollaborationFrames()
        #expect(throws: CollaborationFrames.Failure.self) { try decoder.append(Data([255, 255, 255, 255])) }
        #expect(throws: CollaborationFrames.Failure.self) { try CollaborationFrames.encode(Data(repeating: 0, count: CollaborationFrames.maximumBytes + 1)) }
        let bad = try CollaborationFrames.encode(Data("not json".utf8))
        #expect(throws: CollaborationFrames.Failure.self) { try decoder.append(bad) }
        let good = Data(#"{"type":"resync"}"#.utf8)
        #expect(try decoder.append(CollaborationFrames.encode(good)) == [good])
    }
}
