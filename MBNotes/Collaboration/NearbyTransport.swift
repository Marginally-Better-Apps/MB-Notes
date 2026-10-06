import Foundation
import Network
import NoteEngine

/// Bonjour over TCP, including Apple peer-to-peer Wi-Fi links. No internet signaling is needed.
final class NearbyTransport {
    static let serviceType = "_mbnotes-collab._tcp"
    var listening: (NWEndpoint.Port) -> Void = { _ in }
    var opened: (String) -> Void = { _ in }
    var received: (String, [String: Any]) -> Void = { _, _ in }
    var closed: (String) -> Void = { _ in }
    var status: (String) -> Void = { _ in }
    var fallback: () -> Void = {}
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connections: [String: NWConnection] = [:]
    private var frames: [String: CollaborationFrames] = [:]
    private var timeout: DispatchWorkItem?
    private var joiningName: String?

    private var parameters: NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        return parameters
    }
    func host(name: String, advertise: Bool = true) throws {
        stop()
        let listener = try NWListener(using: parameters)
        if advertise { listener.service = NWListener.Service(name: name, type: Self.serviceType) }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.connections.count < 9 else { connection.cancel(); return }
            self.attach(connection, id: "nearby-" + UUID().uuidString)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let port = self?.listener?.port { self?.listening(port) }
            if case .failed(let error) = state { self?.status("Nearby sharing unavailable: \(error.localizedDescription)") }
        }
        self.listener = listener
        listener.start(queue: .main)
    }
    func join(name: String) {
        stop(); joiningName = name
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.connections.isEmpty else { return }
            for result in results {
                if case .service(let service, _, _, _) = result.endpoint, service == name {
                    self.attach(NWConnection(to: result.endpoint, using: self.parameters), id: "nearby-host")
                    return
                }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.fallback() }
        }
        self.browser = browser
        browser.start(queue: .main)
        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.browser?.cancel(); self.browser = nil
            if !self.connections.values.contains(where: { $0.state == .ready }) {
                for connection in self.connections.values { connection.cancel() }
                self.connections = [:]; self.frames = [:]
                self.fallback()
            }
        }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
    }
    /// A direct endpoint is also used by the network integration tests.
    func connect(to endpoint: NWEndpoint) { attach(NWConnection(to: endpoint, using: parameters), id: "nearby-host") }
    private func attach(_ connection: NWConnection, id: String) {
        connections[id] = connection; frames[id] = CollaborationFrames()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, self.connections[id] === connection else { return }
            switch state {
            case .ready:
                self.timeout?.cancel(); self.timeout = nil
                self.opened(id)
                self.receive(id)
            case .failed, .cancelled:
                self.connections[id] = nil; self.frames[id] = nil
                self.closed(id)
                if self.joiningName != nil {
                    self.status("Nearby connection lost. Trying internet sharing…")
                    self.fallback()
                }
            default: break
            }
        }
        connection.start(queue: .main)
    }
    private func receive(_ id: String) {
        guard let connection = connections[id] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, complete, error in
            guard let self, self.connections[id] === connection else { return }
            do {
                if let data {
                    let payloads = try self.frames[id]?.append(data) ?? []
                    for payload in payloads {
                        guard let message = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else { continue }
                        self.received(id, message)
                    }
                }
                if complete || error != nil { self.close(id); return }
                self.receive(id)
            } catch { self.close(id) }
        }
    }
    func send(_ message: [String: Any], to id: String) {
        guard let connection = connections[id] else { return }
        do {
            let payload = try CollaborationFrames.encode(JSONSerialization.data(withJSONObject: message))
            connection.send(content: payload, completion: .contentProcessed { [weak self] error in if error != nil { self?.close(id) } })
        } catch { close(id) }
    }
    func close(_ id: String) { connections[id]?.cancel() }
    func stop() {
        timeout?.cancel(); timeout = nil; joiningName = nil
        browser?.cancel(); browser = nil; listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }
        connections = [:]; frames = [:]
    }
}
