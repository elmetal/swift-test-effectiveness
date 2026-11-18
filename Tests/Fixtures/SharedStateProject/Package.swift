// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SharedStateProject",
    targets: [
        .target(name: "Shared"),
        .testTarget(name: "SharedTests", dependencies: ["Shared"]),
    ]
)
