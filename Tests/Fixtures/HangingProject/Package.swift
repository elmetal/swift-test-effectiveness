// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HangingProject",
    targets: [
        .target(name: "Counter"),
        .testTarget(name: "CounterTests", dependencies: ["Counter"]),
    ]
)
