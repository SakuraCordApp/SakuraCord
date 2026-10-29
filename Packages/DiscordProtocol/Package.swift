// swift-tools-version: 6.4
import Foundation
import PackageDescription

// Set with the app package's `SAKURACORD_MOTION_BENCHMARK=1` build.
let motionBenchmarkSettings: [SwiftSetting] =
    ProcessInfo.processInfo.environment["SAKURACORD_MOTION_BENCHMARK"] == "1"
    ? [.define("SAKURACORD_MOTION_BENCHMARK")] : []

let package = Package(
    name: "DiscordProtocol",
    platforms: [.macOS(.v27)],
    products: [.library(name: "DiscordProtocol", targets: ["DiscordProtocol"])],
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
            resources: [.process("Resources")],
            swiftSettings: motionBenchmarkSettings
        ),
        .testTarget(name: "DiscordProtocolTests", dependencies: ["DiscordProtocol"])
    ]
)
