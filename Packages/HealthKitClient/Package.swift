// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HealthKitClient",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v15)], // macOS target lets `swift test` run on CI without a simulator
    products: [
        .library(name: "HealthKitClient", targets: ["HealthKitClient"]),
    ],
    dependencies: [.package(path: "../Core")],
    targets: [
        .target(
            name: "HealthKitClient",
            dependencies: [.product(name: "Core", package: "Core")],
            resources: [.process("Localizable.xcstrings")],
            swiftSettings: [.swiftLanguageMode(.v6)],
        ),
        .testTarget(
            name: "HealthKitClientTests",
            dependencies: ["HealthKitClient"],
        ),
    ],
)
