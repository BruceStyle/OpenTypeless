// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenTypeless",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OpenTypeless", targets: ["OpenTypeless"]),
        .executable(name: "TranscriptionBenchmark", targets: ["TranscriptionBenchmark"])
    ],
    targets: [
        .target(name: "OpenTypelessCore"),
        .executableTarget(name: "OpenTypeless", dependencies: ["OpenTypelessCore"]),
        .executableTarget(name: "TranscriptionBenchmark", dependencies: ["OpenTypelessCore"], path: "Tools/TranscriptionBenchmark", exclude: ["README.md"]),
        .testTarget(name: "OpenTypelessCoreTests", dependencies: ["OpenTypelessCore"]),
        .testTarget(name: "OpenTypelessAppTests", dependencies: ["OpenTypeless"])
    ],
    swiftLanguageModes: [.v5]
)
