// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "SakuraCordPersistence",
    platforms: [.macOS(.v27)],
    products: [.library(name: "SakuraCordPersistence", targets: ["SakuraCordPersistence"])],
    dependencies: [
        .package(path: "../SakuraCordModels"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")
    ],
    targets: [
        .target(name: "SakuraCordPersistence", dependencies: ["SakuraCordModels", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "SakuraCordPersistenceTests", dependencies: ["SakuraCordPersistence"])
    ]
)
