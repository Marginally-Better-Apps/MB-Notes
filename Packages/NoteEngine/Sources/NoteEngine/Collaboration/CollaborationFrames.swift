import Foundation

/// Bounded length-prefixed JSON frames, shared by nearby native streams.
public struct CollaborationFrames {
    public static let maximumBytes = 4 * 1024 * 1024
    public enum Failure: Error { case oversized, invalidJSON }
    private var buffer = Data()
    public init() {}
    public static func encode(_ payload: Data) throws -> Data {
        guard payload.count <= maximumBytes else { throw Failure.oversized }
        let count = UInt32(payload.count)
        return Data([UInt8(count >> 24), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)]) + payload
    }
    public mutating func append(_ bytes: Data) throws -> [Data] {
        buffer.append(bytes)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let prefix = Array(buffer.prefix(4))
            let count = prefix.reduce(0) { ($0 << 8) | Int($1) }
            guard count <= Self.maximumBytes else { buffer = Data(); throw Failure.oversized }
            guard buffer.count >= count + 4 else { break }
            let payload = Data(buffer.dropFirst(4).prefix(count))
            guard (try? JSONSerialization.jsonObject(with: payload)) != nil else { buffer = Data(); throw Failure.invalidJSON }
            frames.append(payload)
            buffer.removeFirst(count + 4)
        }
        return frames
    }
}
