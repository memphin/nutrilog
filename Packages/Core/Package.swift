// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Core",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v15)], // macOS target lets `swift test` run on CI without a simulator
    products: [
        .library(name: "Core", targets: ["Core"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "Core",
            dependencies: [],
            resources: [.process("Localizable.xcstrings")],
            swiftSettings: [.swiftLanguageMode(.v6)],
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"],
        ),
    ],
)
