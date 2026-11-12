// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Scanner",
    defaultLocalization: "en",
    // The camera UI is iOS-only (`#if os(iOS)`); the macOS target lets `swift test` run the pure logic on CI.
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "Scanner", targets: ["Scanner"]),
    ],
    dependencies: [
        .package(path: "../Core"),
    ],
    targets: [
        .target(
            name: "Scanner",
            dependencies: ["Core"],
            resources: [.process("Localizable.xcstrings")],
            swiftSettings: [.swiftLanguageMode(.v6)],
        ),
        .testTarget(
            name: "ScannerTests",
            dependencies: ["Scanner", "Core"],
        ),
    ],
)
