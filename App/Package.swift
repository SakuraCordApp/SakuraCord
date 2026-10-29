// swift-tools-version: 6.4
import PackageDescription
import Foundation

let sparkleDependency: Package.Dependency = ProcessInfo.processInfo.environment["SAKURACORD_SPARKLE_PACKAGE_PATH"]
    .map { .package(path: $0) }
    ?? .package(url: "https://github.com/SakuraCordApp/Sparkle", exact: "2.10.0-sakuracord.1")

// Opt-in developer tooling: `SAKURACORD_MOTION_BENCHMARK=1` compiles the side
// chat motion benchmark into the app and the mock provider's fixture for it.
// Normal Debug and Release builds compile none of it.
let motionBenchmarkSettings: [SwiftSetting] =
    ProcessInfo.processInfo.environment["SAKURACORD_MOTION_BENCHMARK"] == "1"
    ? [.define("SAKURACORD_MOTION_BENCHMARK")] : []

let package = Package(
    name: "SakuraCordApp",
    platforms: [.macOS(.v27)],
    products: [
        .executable(name: "SakuraCord", targets: ["SakuraCordLauncher"]),
        .executable(name: "SakuraCordPluginHost", targets: ["SakuraCordPluginHost"])
    ],
    dependencies: [
        .package(path: "../Packages/SakuraCordModels"),
        .package(path: "../Packages/DiscordProtocol"),
        .package(path: "../Packages/SakuraCordPersistence"),
        .package(path: "../Packages/MessageRendering"),
        .package(path: "../Packages/MediaPipeline"),
        .package(path: "../Packages/SakuraCordPluginSDK"),
        .package(url: "https://github.com/airbnb/lottie-ios.git", exact: "4.6.1"),
        sparkleDependency,
        .package(
            url: "https://github.com/llsc12/hcaptcha",
            revision: "29de12bd290c5cc9c61b3e3c15fe9a9d21449465"
        )
    ],
    targets: [
        .target(
            name: "SakuraCord",
            dependencies: [
                "SakuraCordModels", "DiscordProtocol", "SakuraCordPersistence",
                "MessageRendering", "MediaPipeline", "SakuraCordPluginSDK",
                .product(name: "Lottie", package: "lottie-ios"),
                .product(name: "HCaptcha", package: "hcaptcha"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            resources: [.process("Resources")],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .defaultIsolation(MainActor.self),
                .interoperabilityMode(.Cxx)
            ] + motionBenchmarkSettings
        ),
        .executableTarget(
            name: "SakuraCordLauncher",
            dependencies: ["SakuraCord"],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        .executableTarget(name: "SakuraCordPluginHost", dependencies: ["SakuraCordPluginSDK"]),
        .testTarget(
            name: "SakuraCordAppTests",
            dependencies: ["SakuraCord", "DiscordProtocol", "MediaPipeline"],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        )
    ]
)
