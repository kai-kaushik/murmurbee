// swift-tools-version:6.0
import PackageDescription

// Runs FluidAudio's diarizers and Parakeet over lists of meeting files and writes RTTM / word-timing JSON,
// so every system is scored by the same Python scorer (scripts/meetings/score.py).
let package = Package(
    name: "MeetBench",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../../../vendor/FluidAudio")],
    targets: [
        .executableTarget(
            name: "MeetBench",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
