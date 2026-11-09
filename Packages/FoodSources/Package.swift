// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FoodSources",
    platforms: [.iOS(.v26), .macOS(.v15)], // macOS target lets `swift test` run on CI without a simulator
    products: [
        .library(name: "FoodSources", targets: ["FoodSources"]),
    ],
    dependencies: [.package(path: "../Core")],
    targets: [
        .target(
            name: "FoodSources",
            dependencies: [.product(name: "Core", package: "Core")],
            swiftSettings: [.swiftLanguageMode(.v6)],
        ),
        .testTarget(
            name: "FoodSourcesTests",
            dependencies: ["FoodSources"],
            resources: [.copy("Fixtures")],
        ),
    ],
)
