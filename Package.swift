// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Flaj",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Flaj", path: "Sources/Flaj")
    ]
)
