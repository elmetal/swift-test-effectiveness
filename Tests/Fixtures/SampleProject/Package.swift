// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SampleProject",
    targets: [
        .target(name: "Sample"),
        .testTarget(name: "SampleTests", dependencies: ["Sample"]),
    ]
)
