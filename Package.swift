// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Plainsay",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PlainsayCore", targets: ["PlainsayCore"]),
        .executable(name: "PlainsayApp", targets: ["PlainsayApp"]),
        .executable(name: "BenchmarkCLI", targets: ["BenchmarkCLI"]),
        .executable(name: "MiniTranscribeServer", targets: ["MiniTranscribeServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.1.0"),
        // FluidAudio is still pre-1.0 and its ASR API changes between minor
        // releases, so keep the integration on the version it is tested with.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.6"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.5"),
        // Only for MiniTranscribeServer's HTTP layer — not linked into the app.
        .package(url: "https://github.com/vapor/vapor.git", from: "4.99.0"),
    ],
    targets: [
        .target(
            name: "PlainsayCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            resources: [.process("Resources/CoreLocalizable.xcstrings")]
        ),
        .executableTarget(
            name: "PlainsayApp",
            dependencies: [
                "PlainsayCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [.process("Resources/Localizable.xcstrings")]
        ),
        .testTarget(
            name: "PlainsayCoreTests",
            dependencies: ["PlainsayCore"]
        ),
        .executableTarget(
            name: "BenchmarkCLI",
            dependencies: ["PlainsayCore"]
        ),
        .executableTarget(
            name: "MiniTranscribeServer",
            dependencies: [
                "PlainsayCore",
                .product(name: "Vapor", package: "vapor"),
            ]
        ),
    ]
)
