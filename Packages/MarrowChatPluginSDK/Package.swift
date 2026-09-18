// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "MarrowChatPluginSDK",
    platforms: [.macOS(.v27)],
    products: [.library(name: "MarrowChatPluginSDK", targets: ["MarrowChatPluginSDK"])],
    targets: [
        .target(name: "MarrowChatPluginSDK"),
        .testTarget(name: "MarrowChatPluginSDKTests", dependencies: ["MarrowChatPluginSDK"])
    ]
)
