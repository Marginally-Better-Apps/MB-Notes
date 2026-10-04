import Foundation
import Gist
import PencilKit
import Shapes
import Title

/// Shape snapping on a PencilKit canvas with Desert Ant's Shapes model.
@MainActor
public enum ShapeSnapping {
    private static let recognizer = Shapes()

    /// Draw a stroke, pause, and it previews a clean shape; lift to keep it.
    public static func setEnabled(_ enabled: Bool, on canvas: PKCanvasView) {
        if enabled {
            ModelManager.shared.ensureSmallModel(.shapes)
            canvas.enableShapeSnapping(using: recognizer)
        } else {
            canvas.disableShapeSnapping()
        }
    }
}

/// Topic tags and titles from small on-device models.
public enum TextInsights {
    /// Up to three topic names for a note's text, using Gist's English model.
    public static func topics(for text: String) async -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 20 else { return [] }
        let gist = Gist(variant: .english)
        guard gist.isDownloaded() else { return [] }
        let topics = (try? await gist.classify(String(trimmed.prefix(4000)), topK: 3)) ?? []
        return topics.map(\.name)
    }

    /// A short title and description from the Title model, when it is downloaded.
    public static func title(for text: String) async -> (title: String, description: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 20 else { return nil }
        #if targetEnvironment(simulator)
        return nil
        #else
        let directory = ModelManager.titleDirectory
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path),
              let titles = try? await Titles(directory: directory),
              let card = try? await titles.describe(String(trimmed.prefix(3000))),
              !card.title.isEmpty else { return nil }
        return (card.title, card.description)
        #endif
    }
}
