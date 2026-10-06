import Foundation

struct CollaborationInvitation: Codable {
    let v: Int
    let session: String
    let document: String
    let token: String
    let peer: String
    let nearby: String
    let page: String?

    init(documentID: UUID, pageID: UUID? = nil) {
        let id = UUID().uuidString.lowercased()
        v = 1; session = id; document = documentID.uuidString.lowercased()
        token = UUID().uuidString + UUID().uuidString
        page = pageID?.uuidString.lowercased()
        peer = "mb-" + id; nearby = "mb-" + String(id.prefix(8))
    }
    static func parse(_ input: String) throws -> Self {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String
        if raw.hasPrefix("{") { value = raw }
        else if let url = URLComponents(string: raw) {
            let fragment = URLComponents(string: "https://invitation.invalid/?" + (url.fragment ?? ""))?.queryItems
            guard let found = (url.queryItems ?? []).first(where: { $0.name == "invitation" })?.value ?? fragment?.first(where: { $0.name == "mb" })?.value else { throw CocoaError(.fileReadCorruptFile) }
            value = found
        } else { throw CocoaError(.fileReadCorruptFile) }
        let invitation = try JSONDecoder().decode(Self.self, from: Data(value.utf8))
        guard invitation.v == 1, invitation.token.count >= 24, UUID(uuidString: invitation.document) != nil else { throw CocoaError(.fileReadCorruptFile) }
        return invitation
    }
    var dictionary: [String: Any] { (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(self))) as? [String: Any] ?? [:] }
}
