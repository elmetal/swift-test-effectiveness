// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReferencedProject",
    targets: [
        .target(name: "Store"),
        .testTarget(name: "StoreTests", dependencies: ["Store"]),
    ]
)
