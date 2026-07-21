// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "DiscordProtocol",
    platforms: [.macOS(.v27)],
    products: [.library(name: "DiscordProtocol", targets: ["DiscordProtocol"])],
    dependencies: [.package(path: "../SakuraCordModels")],
    targets: [
        .target(
            name: "DiscordProtocol",
            dependencies: ["SakuraCordModels"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "DiscordProtocolTests", dependencies: ["DiscordProtocol"])
    ]
)
