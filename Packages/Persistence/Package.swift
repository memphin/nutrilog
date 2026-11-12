// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Persistence",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v15)], // macOS target lets `swift test` run on CI without a simulator
    products: [
        .library(name: "Persistence", targets: ["Persistence"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(path: "../Core"),
    ],
    targets: [
        .target(
            name: "Persistence",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Core", package: "Core"),
            ],
            resources: [.copy("Migrations"), .process("Localizable.xcstrings")],
            swiftSettings: [.swiftLanguageMode(.v6)],
        ),
        .testTarget(
            name: "PersistenceTests",
            dependencies: ["Persistence"],
        ),
    ],
)
