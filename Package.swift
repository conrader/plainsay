// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Plainsay",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PlainsayCore", targets: ["PlainsayCore"]),
        .executable(name: "PlainsayApp", targets: ["PlainsayApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.1.0"),
    ],
    targets: [
        .target(
            name: "PlainsayCore",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")]
        ),
        .executableTarget(
            name: "PlainsayApp",
            dependencies: ["PlainsayCore"]
        ),
        .testTarget(
            name: "PlainsayCoreTests",
            dependencies: ["PlainsayCore"]
        ),
    ]
)
