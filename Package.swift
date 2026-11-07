// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-test-effectiveness",
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "swift-test-effectiveness",
            targets: ["swift-test-effectiveness"]
        ),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "swift-test-effectiveness"
        ),
        .testTarget(
            name: "swift-test-effectivenessTests",
            dependencies: ["swift-test-effectiveness"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
