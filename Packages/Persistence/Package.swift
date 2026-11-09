// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Persistence",
    platforms: [.iOS(.v26), .macOS(.v15)], // macOS target lets `swift test` run on CI without a simulator
    products: [
        .library(name: "Persistence", targets: ["Persistence"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "Persistence",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("Migrations")],
            swiftSettings: [.swiftLanguageMode(.v6)],
        ),
        .testTarget(
            name: "PersistenceTests",
            dependencies: ["Persistence"],
        ),
    ],
)
