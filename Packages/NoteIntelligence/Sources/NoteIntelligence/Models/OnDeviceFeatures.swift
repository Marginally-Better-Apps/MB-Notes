import Foundation
import Gist
import PencilKit
import Shapes
import Title

/// Shape snapping on a PencilKit canvas with Desert Ant's Shapes model, as a fallback
/// behind the engine's own `StrokeBeautifier`.
@MainActor
public enum ShapeSnapping {
    /// Enables the SDK's snapping only when the model is switched on in Settings.
    public static func setEnabled(_ enabled: Bool, on canvas: PKCanvasView) {
        let manager = ModelManager.shared
        if enabled, manager.isEnabled(.shapes) {
            manager.ensureSmallModel(.shapes)
            canvas.enableShapeSnapping(using: manager.shapes)
        } else {
            canvas.disableShapeSnapping()
        }
    }

    /// The shared recognizer, for callers that classify strokes themselves.
    public static var recognizer: Shapes? {
        ModelManager.shared.isUsable(.shapes) ? ModelManager.shared.shapes : nil
    }
}

/// Topic tags and titles from small on-device models.
public enum TextInsights {
    /// Up to three topic names for a note's text, using Gist's English model.
    public static func topics(for text: String) async -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 20, await ModelManager.shared.isUsable(.gist) else { return [] }
        let gist = Gist(variant: .english)
        let topics = (try? await gist.classify(String(trimmed.prefix(4000)), topK: 3)) ?? []
        return topics.map(\.name)
    }

    /// A short title and description from the Title model, when it is downloaded and on.
    public static func title(for text: String) async -> (title: String, description: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 20, await ModelManager.shared.isUsable(.title) else { return nil }
        #if targetEnvironment(simulator)
        return nil
        #else
        let directory = ModelManager.titleDirectory
        guard let titles = try? await Titles(directory: directory),
              let card = try? await titles.describe(String(trimmed.prefix(3000))),
              !card.title.isEmpty else { return nil }
        return (card.title, card.description)
        #endif
    }
}
