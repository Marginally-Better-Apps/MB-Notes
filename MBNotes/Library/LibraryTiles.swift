import NoteEngine
import SwiftUI

/// The classic folder silhouette: a tab on the top-left above a rounded body.
struct FolderShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r = rect.width * 0.08
        let tabWidth = rect.width * 0.42
        let tabHeight = rect.height * 0.12
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + tabWidth - r, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + tabWidth + r * 0.6, y: rect.minY + tabHeight), control: CGPoint(x: rect.minX + tabWidth, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY + tabHeight))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + tabHeight + r), control: CGPoint(x: rect.maxX, y: rect.minY + tabHeight))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// A folder drawn in its color with its symbol and stickers.
struct FolderArt: View {
    let metadata: FolderMetadata
    var catalog: PackCatalog

    var body: some View {
        GeometryReader { geo in
            let color = Color(hex: metadata.color)
            ZStack {
                // Back sheet peeking out, like papers inside the folder.
                RoundedRectangle(cornerRadius: geo.size.width * 0.06)
                    .fill(.white.opacity(0.9))
                    .frame(width: geo.size.width * 0.86, height: geo.size.height * 0.7)
                    .rotationEffect(.degrees(-3))
                    .offset(y: -geo.size.height * 0.08)
                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                FolderShape()
                    .fill(LinearGradient(colors: [color.mix(with: .white, by: 0.18), color], startPoint: .top, endPoint: .bottom))
                    .overlay(FolderShape().stroke(.white.opacity(0.35), lineWidth: 1))
                    .overlay(alignment: .topLeading) {
                        // Glassy highlight along the top edge.
                        FolderShape()
                            .fill(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center))
                    }
                    .frame(height: geo.size.height * 0.82)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .shadow(color: color.opacity(0.35), radius: 8, y: 4)
                Image(systemName: metadata.symbol)
                    .font(.system(size: geo.size.width * 0.22, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    .offset(y: geo.size.height * 0.1)
                ForEach(metadata.stickers) { placed in
                    StickerView(ref: placed.sticker, catalog: catalog)
                        .frame(width: geo.size.width * 0.3 * placed.scale, height: geo.size.width * 0.3 * placed.scale)
                        .rotationEffect(.radians(placed.rotation))
                        .position(x: placed.x * geo.size.width, y: placed.y * geo.size.height)
                }
            }
        }
        .aspectRatio(1.15, contentMode: .fit)
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
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 8) {
            FolderArt(metadata: item.folder ?? FolderMetadata(color: "#8056F6", symbol: "folder.fill"), catalog: app.catalog)
            Text(item.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(item.modifiedAt, format: .relative(presentation: .named))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct NoteTile: View {
    let item: LibraryEntry
    @Environment(AppModel.self) private var app
    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .aspectRatio(0.75, contentMode: .fit)
            .clipShape(.rect(topLeadingRadius: isNotebook ? 4 : 10, bottomLeadingRadius: isNotebook ? 4 : 10, bottomTrailingRadius: 10, topTrailingRadius: 10))
            .overlay(alignment: .leading) {
                if isNotebook {
                    // Binding shadow so notebooks read as books.
                    LinearGradient(colors: [.black.opacity(0.22), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 10)
                        .clipShape(.rect(topLeadingRadius: 4, bottomLeadingRadius: 4))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let count = item.manifest?.recordings.count, count > 0 {
                    Image(systemName: "waveform")
                        .font(.caption.weight(.bold))
                        .padding(6)
                        .glassEffect(.regular.tint(Brand.pink.opacity(0.4)), in: .circle)
                        .padding(6)
                }
            }
            .shadow(color: .black.opacity(0.14), radius: 6, y: 3)
            Text(item.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(item.modifiedAt, format: .relative(presentation: .named))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .task(id: item.modifiedAt) {
            image = ThumbnailCache.shared.cached(for: item)
            image = await ThumbnailCache.shared.image(for: item, catalog: app.catalog)
        }
    }

    private var isNotebook: Bool { item.manifest?.kind == .notebook }
}
