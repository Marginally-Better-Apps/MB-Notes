import NoteEngine
import PDFKit
import SwiftUI
import VisionKit

/// The system document camera. Scanned pages become one PDF handed to `onScan`.
struct DocumentScannerView: UIViewControllerRepresentable {
    var onScan: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScannerView
        init(parent: DocumentScannerView) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let pdf = PDFDocument()
            for index in 0..<scan.pageCount {
                if let page = PDFPage(image: scan.imageOfPage(at: index)) { pdf.insert(page, at: pdf.pageCount) }
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Scan \(Date().formatted(.dateTime.month(.abbreviated).day().hour().minute())).pdf")
            pdf.write(to: url)
            parent.dismiss()
            parent.onScan(url)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.dismiss()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            parent.dismiss()
        }
    }
}
