// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "MarrowChatPersistence",
    platforms: [.macOS(.v27)],
    products: [.library(name: "MarrowChatPersistence", targets: ["MarrowChatPersistence"])],
    dependencies: [
        .package(path: "../MarrowChatModels"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")
    ],
    targets: [
        .target(name: "MarrowChatPersistence", dependencies: ["MarrowChatModels", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(
            name: "MarrowChatPersistenceTests",
            dependencies: [
                "MarrowChatPersistence",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        )
    ]
)
