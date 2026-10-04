// swift-tools-version: 6.2
import PackageDescription

// On-device and bring-your-own-key intelligence for MB Notes.
//
// - Desert Ant Labs models (shape snapping, speech, audio cleanup, tagging, titles)
//   run on the Neural Engine. They are source-available and free below 100k
//   monthly active devices per model; see docs/MODELS.md.
// - FluidAudio provides on-device speaker diarization (Apache-2.0).
// - mlx-swift-lm runs an optional small Hugging Face LLM on device (MIT).
// - Remote AI goes through any OpenAI-compatible endpoint with the user's own key.
let package = Package(
    name: "NoteIntelligence",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "NoteIntelligence", targets: ["NoteIntelligence"]),
    ],
    dependencies: [
        .package(path: "../NoteEngine"),
        .package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "3.5.0", traits: ["MLX"]),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4", traits: []),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "3.31.3"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.3"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
    ],
    targets: [
        .target(
            name: "NoteIntelligence",
            dependencies: [
                .product(name: "NoteEngine", package: "NoteEngine"),
                .product(name: "Shapes", package: "desert-ant-core"),
                .product(name: "Voz", package: "desert-ant-core"),
                .product(name: "Clear", package: "desert-ant-core"),
                .product(name: "Uhm", package: "desert-ant-core"),
                .product(name: "Gist", package: "desert-ant-core"),
                .product(name: "Title", package: "desert-ant-core"),
                .product(name: "DesertAnt", package: "desert-ant-core"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
