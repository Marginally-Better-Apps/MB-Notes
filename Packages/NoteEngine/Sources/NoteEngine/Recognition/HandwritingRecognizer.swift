#if canImport(UIKit) && canImport(PencilKit)
import CryptoKit
import Foundation
import PencilKit
import Vision

/// Finds handwritten text in a page's ink with Apple's on-device Vision framework.
///
/// Results feed search, "convert to text", and the invisible text layer in PDF
/// exports. Only ink is recognized; imported PDFs already carry their own text.
public enum HandwritingRecognizer {
    public static func fingerprint(of inkData: Data) -> String {
        SHA256.hash(data: inkData).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    public static func recognize(_ drawing: PKDrawing, pageSize: PageSize, languages: [String]? = nil) async throws -> [PageRecognition.Line] {
        guard !drawing.strokes.isEmpty else { return [] }
        // Recognize only the area with ink, rendered large enough for small handwriting.
        let inkBounds = drawing.bounds.insetBy(dx: -12, dy: -12).intersection(CGRect(x: 0, y: 0, width: pageSize.width, height: pageSize.height))
        guard !inkBounds.isNull, inkBounds.width > 4, inkBounds.height > 4 else { return [] }
        let scale = min(3, 2400 / max(inkBounds.width, inkBounds.height))
        guard let image = inkImage(drawing, bounds: inkBounds, scale: scale) else { return [] }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations.compactMap { observation -> PageRecognition.Line? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    // Vision boxes are normalized with a bottom-left origin.
                    let box = observation.boundingBox
                    let rect = Rect(
                        x: inkBounds.minX + box.minX * inkBounds.width,
                        y: inkBounds.minY + (1 - box.maxY) * inkBounds.height,
                        width: box.width * inkBounds.width,
                        height: box.height * inkBounds.height
                    )
                    return PageRecognition.Line(text: candidate.string, confidence: Double(candidate.confidence), box: rect)
                }
                continuation.resume(returning: lines.sorted { ($0.box.y, $0.box.x) < ($1.box.y, $1.box.x) })
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = languages == nil
            if let languages { request.recognitionLanguages = languages }
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    static func inkImage(_ drawing: PKDrawing, bounds: CGRect, scale: CGFloat) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            var ink = UIImage()
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                ink = drawing.image(from: bounds, scale: scale)
            }
            ink.draw(in: CGRect(origin: .zero, size: size))
        }
        return image.cgImage
    }
}
#endif
