// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Scanner",
    platforms: [.iOS(.v26), .macOS(.v15)], // macOS target lets `swift test` run on CI without a simulator
    products: [
        .library(name: "Scanner", targets: ["Scanner"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "Scanner",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v6)],
        ),
        .testTarget(
            name: "ScannerTests",
            dependencies: ["Scanner"],
        ),
    ],
)
