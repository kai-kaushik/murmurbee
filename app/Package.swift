// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MurmurBee",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Pinned to exact commits, so a release can be rebuilt from this repo and upstream changes never slip in.
        .package(url: "https://github.com/FluidInference/FluidAudio", revision: "c79c4106b954f81205113c3343e5a7e59a1089b5"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", revision: "3b339ad6e3b3f44c8121ecff5131c7fd55e075e6"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
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
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
