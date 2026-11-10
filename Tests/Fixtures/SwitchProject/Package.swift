// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwitchProject",
    targets: [
        .target(name: "Switches"),
        .testTarget(name: "SwitchesTests", dependencies: ["Switches"]),
    ]
)
