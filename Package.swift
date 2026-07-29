// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "BabelBar",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "BabelBar",
            path: "Sources/BabelBar"
        ),
        .testTarget(
            name: "BabelBarTests",
            dependencies: ["BabelBar"],
            path: "Tests/BabelBarTests"
        )
    ]
)
