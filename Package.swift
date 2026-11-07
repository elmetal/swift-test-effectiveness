// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-test-effectiveness",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TestEffectivenessCore", targets: ["TestEffectivenessCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.0"),
    ],
    targets: [
        .target(
            name: "TestEffectivenessCore",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "TestEffectivenessCoreTests",
            dependencies: ["TestEffectivenessCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
