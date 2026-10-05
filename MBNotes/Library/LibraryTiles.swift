import NoteEngine
import SwiftUI

/// A flat, Files-style folder: a darker back with a tab, a lighter front body, and the
/// folder's symbol embossed on the front. One tint, no gradients or shadows.
struct FolderGlyph: View {
    let metadata: FolderMetadata
    var showsSymbol = true

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let tint = Color(hex: metadata.color)
            let radius = w * 0.09
            ZStack(alignment: .bottom) {
                // Back panel with the tab.
                UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius, bottomTrailingRadius: radius, topTrailingRadius: radius)
                    .fill(tint.mix(with: .black, by: 0.18))
                    .frame(width: w, height: h * 0.9)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .overlay(alignment: .topLeading) {
                        UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: radius * 0.9)
                            .fill(tint.mix(with: .black, by: 0.18))
                            .frame(width: w * 0.42, height: h * 0.2)
                    }
                // Front body.
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(tint)
                    .frame(width: w, height: h * 0.74)
                if showsSymbol, metadata.symbol != "folder.fill" {
                    Image(systemName: metadata.symbol)
                        .font(.system(size: w * 0.26, weight: .medium))
                        .foregroundStyle(tint.mix(with: .black, by: 0.3))
                        .frame(height: h * 0.74)
                }
            }
            .frame(width: w, height: h)
        }
        .aspectRatio(1.25, contentMode: .fit)
    }
}

/// Renders one sticker from a pack.
struct StickerView: View {
    let ref: ContentRef
    var catalog: PackCatalog
    var embedded: EmbeddedResources?

    var body: some View {
        Canvas { context, size in
            guard let sticker = catalog.resolveSticker(ref, embedded: embedded) else { return }
            context.withCGContext { cg in
                let env = RenderEnvironment(palette: .standard, assetURL: { catalog.assetURL(packID: ref.packID, path: $0) })
                TemplateRenderer.drawSticker(sticker, in: cg, rect: CGRect(origin: .zero, size: size), environment: env)
            }
        }
    }
}

struct FolderTile: View {
    let item: LibraryEntry
    var highlighted = false

    var body: some View {
        VStack(spacing: 6) {
            FolderGlyph(metadata: item.folder ?? FolderMetadata(color: "#6A45E0", symbol: "folder.fill"))
                .padding(.horizontal, 10)
                .scaleEffect(highlighted ? 1.06 : 1)
                .animation(.snappy, value: highlighted)
            Text(item.name)
                .font(.footnote)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(countLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.name), folder, \(countLabel)")
    }

    private var countLabel: String {
        let count = item.itemCount ?? 0
        return count == 1 ? "1 item" : "\(count) items"
    }
}

/// A note's first page or cover, with a hairline border instead of a drop shadow.
struct NoteThumbnail: View {
    let item: LibraryEntry
    @Environment(AppModel.self) private var app
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .aspectRatio(0.75, contentMode: .fit)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
        .overlay(alignment: .leading) {
            if item.manifest?.kind == .notebook {
                Rectangle().fill(.black.opacity(0.1)).frame(width: 1).padding(.leading, 6)
            }
        }
        .task(id: item.modifiedAt) {
            image = ThumbnailCache.shared.cached(for: item)
            image = await ThumbnailCache.shared.image(for: item, catalog: app.catalog)
        }
    }

    private var shape: UnevenRoundedRectangle {
        let leading: CGFloat = item.manifest?.kind == .notebook ? 3 : Radius.tile
        return UnevenRoundedRectangle(topLeadingRadius: leading, bottomLeadingRadius: leading, bottomTrailingRadius: Radius.tile, topTrailingRadius: Radius.tile, style: .continuous)
    }
}

struct NoteTile: View {
    let item: LibraryEntry
    var selected = false

    var body: some View {
        VStack(spacing: 6) {
            NoteThumbnail(item: item)
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .tint)
                            .padding(6)
                    }
                }
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: Radius.tile + 3, style: .continuous).stroke(.tint, lineWidth: 2.5).padding(-3)
                    }
                }
            Text(item.name)
                .font(.footnote)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            HStack(spacing: 4) {
                if item.isPinned { Image(systemName: "pin.fill").font(.system(size: 8)) }
                Text(item.modifiedAt.libraryDescription)
                badges
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityDescription)
    }

    @ViewBuilder private var badges: some View {
        if let manifest = item.manifest {
            if !manifest.recordings.isEmpty { Image(systemName: "waveform") }
            if manifest.kind == .document { Image(systemName: "doc.richtext") }
        }
    }
}

/// A note in list layout: thumbnail, title, date and first line.
struct NoteRow: View {
    let item: LibraryEntry

    var body: some View {
        HStack(spacing: 12) {
            NoteThumbnail(item: item)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if item.isPinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                    Text(item.name).font(.body).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(item.modifiedAt.libraryDescription)
                    if let preview = item.previewLine { Text(preview).lineLimit(1) }
                    if let manifest = item.manifest, !manifest.recordings.isEmpty { Image(systemName: "waveform") }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityDescription)
    }
}

struct FolderRow: View {
    let item: LibraryEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.title2)
                .foregroundStyle(Color(hex: item.folder?.color ?? "#6A45E0"))
                .frame(width: 44)
            Text(item.name).lineLimit(1)
            Spacer()
            Text("\(item.itemCount ?? 0)").foregroundStyle(.secondary)
        }
    }
}

extension LibraryEntry {
    /// The first typed line, for list previews.
    var previewLine: String? {
        guard let manifest else { return nil }
        for page in manifest.pages {
            for element in page.elements {
                if let text = element.text?.string.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    return text.components(separatedBy: .newlines).first
                }
            }
        }
        return nil
    }

    var accessibilityDescription: String {
        guard let manifest else { return name }
        var parts = [name]
        switch manifest.kind {
        case .notebook: parts.append("notebook")
        case .document: parts.append("imported document")
        case .note: parts.append("note")
        }
        parts.append("\(manifest.pages.count) \(manifest.pages.count == 1 ? "page" : "pages")")
        parts.append("edited \(modifiedAt.libraryDescription)")
        if !manifest.recordings.isEmpty { parts.append("has recording") }
        if isPinned { parts.append("pinned") }
        return parts.joined(separator: ", ")
    }
}
