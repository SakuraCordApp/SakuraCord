// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "SakuraCordPluginSDK",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SakuraCordPluginSDK", targets: ["SakuraCordPluginSDK"])],
    targets: [
        .target(name: "SakuraCordPluginSDK"),
        .testTarget(name: "SakuraCordPluginSDKTests", dependencies: ["SakuraCordPluginSDK"])
    ]
)
