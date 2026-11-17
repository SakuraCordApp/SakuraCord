// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "DiscordProtocol",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "DiscordProtocol", targets: ["DiscordProtocol"]),
        // A fictional account behind the provider contract, for test targets only.
        .library(name: "DiscordProtocolTestSupport", targets: ["DiscordProtocolTestSupport"]),
    ],
    dependencies: [
        .package(path: "../SakuraCordModels"),
        .package(url: "https://github.com/facebook/zstd.git", from: "1.5.7"),
    ],
    targets: [
        .target(
            name: "DiscordProtocol",
            dependencies: [
                "SakuraCordModels",
                .product(name: "libzstd", package: "zstd"),
            ],
            resources: [.process("Resources")]
        ),
        .target(name: "DiscordProtocolTestSupport", dependencies: ["DiscordProtocol", "SakuraCordModels"]),
        .testTarget(name: "DiscordProtocolTests", dependencies: ["DiscordProtocol", "DiscordProtocolTestSupport"])
    ]
)
