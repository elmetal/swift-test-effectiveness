// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClosureProject",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Closures"),
        .testTarget(name: "ClosuresTests", dependencies: ["Closures"]),
    ]
)
