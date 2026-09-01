// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "SakuraCordApp",
    platforms: [.macOS(.v27)],
    products: [
        .executable(name: "SakuraCord", targets: ["SakuraCord"]),
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
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
        .package(
            url: "https://github.com/llsc12/hcaptcha",
            revision: "29de12bd290c5cc9c61b3e3c15fe9a9d21449465"
        )
    ],
    targets: [
        .executableTarget(
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
            ]
        ),
        .executableTarget(name: "SakuraCordPluginHost", dependencies: ["SakuraCordPluginSDK"]),
        .testTarget(
            name: "SakuraCordAppTests",
            dependencies: ["SakuraCord", "DiscordProtocol", "MediaPipeline"],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        )
    ]
)
