// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "asrbench",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../vendor/FluidAudio")],
    targets: [
        .executableTarget(name: "asrbench", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")])
    ]
)
