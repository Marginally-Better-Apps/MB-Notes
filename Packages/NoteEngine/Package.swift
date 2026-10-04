// swift-tools-version: 6.2
import PackageDescription

// The note engine: document format, content-pack loader, template renderer,
// and import/export. Everything the app shows on a page is data that flows
// through here; the app's built-in papers, covers, and stickers are just
// another content pack.
let package = Package(
    name: "NoteEngine",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "NoteEngine", targets: ["NoteEngine"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(
            name: "NoteEngine",
            dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation")]
        ),
        .testTarget(
            name: "NoteEngineTests",
            dependencies: ["NoteEngine", .product(name: "ZIPFoundation", package: "ZIPFoundation")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
