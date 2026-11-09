// swift-tools-version: 6.2
import PackageDescription

/// Glue between the online sources and the local database: the barcode lookup pipeline (local → OFF cache → OFF)
/// and saving local copies of online foods. A package of its own so Persistence and FoodSources stay independent.
let package = Package(
    name: "FoodLookup",
    platforms: [.iOS(.v26), .macOS(.v15)], // macOS target lets `swift test` run on CI without a simulator
    products: [
        .library(name: "FoodLookup", targets: ["FoodLookup"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../Persistence"),
        .package(path: "../FoodSources"),
    ],
    targets: [
        .target(
            name: "FoodLookup",
            dependencies: [
                .product(name: "Core", package: "Core"),
                .product(name: "Persistence", package: "Persistence"),
                .product(name: "FoodSources", package: "FoodSources"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)],
        ),
        .testTarget(
            name: "FoodLookupTests",
            dependencies: [
                "FoodLookup",
                .product(name: "Core", package: "Core"),
                .product(name: "Persistence", package: "Persistence"),
                .product(name: "FoodSources", package: "FoodSources"),
            ],
        ),
    ],
)
