// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Quix8D",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Quix8D",
            path: "Sources/Quix8D"
        ),
        .testTarget(
            name: "Quix8DTests",
            dependencies: ["Quix8D"],
            path: "Tests/Quix8DTests"
        ),
    ]
)
