// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-test-effectiveness",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "swift-test-effectiveness", targets: ["swift-test-effectiveness"]),
        .library(name: "TestEffectivenessCore", targets: ["TestEffectivenessCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "TestEffectivenessCore",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .executableTarget(
            name: "swift-test-effectiveness",
            dependencies: [
                "TestEffectivenessCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "TestEffectivenessCoreTests",
            dependencies: ["TestEffectivenessCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
