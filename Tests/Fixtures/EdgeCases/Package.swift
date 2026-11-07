// swift-tools-version: 6.2
import PackageDescription

// Constructs the schemata rewriter must keep compilable. Used by the integration test.
let package = Package(
    name: "EdgeCases",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Edge"),
        .target(name: "MainActorDefault", swiftSettings: [.defaultIsolation(MainActor.self)]),
        .testTarget(name: "EdgeTests", dependencies: ["Edge", "MainActorDefault"]),
    ]
)
