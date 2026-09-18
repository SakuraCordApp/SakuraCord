// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "MarrowChatApp",
    platforms: [.macOS(.v27)],
    products: [
        .executable(name: "MarrowChat", targets: ["MarrowChat"]),
        .executable(name: "MarrowChatPluginHost", targets: ["MarrowChatPluginHost"])
    ],
    dependencies: [
        .package(path: "../Packages/MarrowChatModels"),
        .package(path: "../Packages/DiscordProtocol"),
        .package(path: "../Packages/MarrowChatPersistence"),
        .package(path: "../Packages/MessageRendering"),
        .package(path: "../Packages/MediaPipeline"),
        .package(path: "../Packages/MarrowChatPluginSDK"),
        .package(url: "https://github.com/airbnb/lottie-ios.git", exact: "4.6.1"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
        .package(
            url: "https://github.com/llsc12/hcaptcha",
            revision: "29de12bd290c5cc9c61b3e3c15fe9a9d21449465"
        )
    ],
    targets: [
        .executableTarget(
            name: "MarrowChat",
            dependencies: [
                "MarrowChatModels", "DiscordProtocol", "MarrowChatPersistence",
                "MessageRendering", "MediaPipeline", "MarrowChatPluginSDK",
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
        .executableTarget(name: "MarrowChatPluginHost", dependencies: ["MarrowChatPluginSDK"]),
        .testTarget(
            name: "MarrowChatAppTests",
            dependencies: ["MarrowChat", "DiscordProtocol", "MediaPipeline"],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        )
    ]
)
