// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MurmurBee",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../vendor/FluidAudio"),
        .package(path: "../vendor/mlx-swift-lm"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "MurmurBee",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
