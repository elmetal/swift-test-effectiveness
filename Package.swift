// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "swift-test-effectiveness",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "swift-test-effectiveness", targets: ["swift-test-effectiveness"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        // No semantic-version tags; pinned to the commit tagged swift-6.4.2-RELEASE.
        .package(url: "https://github.com/swiftlang/indexstore-db.git", revision: "64aa0b26913249c4e7c21d351a215fba02702003"),
    ],
    targets: [
        .target(
            name: "TestEffectivenessCore",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "IndexStoreDB", package: "indexstore-db"),
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
