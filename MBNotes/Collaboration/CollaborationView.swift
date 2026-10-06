import AVFoundation
import SwiftUI
import UIKit

struct CollaborationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var client: CollaborationClient
    @State private var link = ""
    @State private var scanning = false
    init(model: EditorModel? = nil, invitation: String? = nil) {
        _client = State(initialValue: CollaborationClient(model: model, invitation: invitation))
    }
    var body: some View {
        NavigationStack {
            Group {
                if client.model != nil && client.invitation == nil {
                    ProgressView("Preparing live note…").task { client.prepareHost() }
                } else if client.model != nil || client.didJoin {
                    CollaborationSurface(client: client)
                } else {
                    Form {
                        Section("Join a live note") {
                            TextField("Session invitation", text: $link, axis: .vertical)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .accessibilityIdentifier("collaboration-invitation")
                            Button("Join session") { client.join(link) }.disabled(link.isEmpty)
                            Button { scanning = true } label: { Label("Scan QR code", systemImage: "qrcode.viewfinder") }
                        }
                        Section { Text("The host keeps the note. Stay connected to view and edit together.") }
                    }
                }
            }
            .navigationTitle(client.model != nil ? "Live collaboration" : "Join live note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { client.stop(); dismiss() } } }
        }
        .sheet(isPresented: $scanning) {
            NavigationStack {
                CollaborationQRScanner { value in scanning = false; link = value; client.join(value) }
                    .navigationTitle("Scan invitation")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanning = false }.accessibilityIdentifier("cancel-collaboration-scan") } }
            }
        }
        .alert("Collaboration", isPresented: Binding(get: { client.error != nil }, set: { if !$0 { client.error = nil } })) {
            Button("OK") { client.error = nil }
        } message: { Text(client.error ?? "") }
        .onChange(of: scenePhase) { if scenePhase == .background { client.stop(); dismiss() } }
        .onDisappear { client.stop() }
    }
}
private struct CollaborationSurface: UIViewControllerRepresentable {
    let client: CollaborationClient
    func makeUIViewController(context: Context) -> CollaborationWebController { CollaborationWebController(client: client) }
    func updateUIViewController(_ controller: CollaborationWebController, context: Context) {}
}
private struct CollaborationQRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController { ScannerController(found: found) }
    func updateUIViewController(_ controller: ScannerController, context: Context) {}
    static func dismantleUIViewController(_ controller: ScannerController, coordinator: ()) { controller.stop() }
}
private final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "mbnotes.collaboration.camera")
    private var preview: AVCaptureVideoPreviewLayer?
    private var consumed = false
    private let found: (String) -> Void
    init(found: @escaping (String) -> Void) { self.found = found; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
            DispatchQueue.main.async { if allowed { self?.configure() } else { self?.unavailable() } }
        }
    }
    private func configure() {
        guard !consumed else { return }
        guard let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else { unavailable(); return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { unavailable(); return }
        session.addOutput(output); output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session); preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview); self.preview = preview; preview.frame = view.bounds
        let session = self.session
        captureQueue.async { session.startRunning() }
    }
    private func unavailable() {
        let label = UILabel(); label.text = "Camera unavailable. Paste the invitation link instead."
        label.textColor = .white; label.numberOfLines = 0; label.textAlignment = .center
        label.frame = view.bounds.insetBy(dx: 24, dy: 24); label.autoresizingMask = [.flexibleWidth, .flexibleHeight]; view.addSubview(label)
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !consumed, let value = metadataObjects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
        consumed = true; stop(); found(value)
    }
    func stop() { consumed = true; let session = self.session; captureQueue.async { session.stopRunning() } }
}
