// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "MarrowChatModels",
    platforms: [.macOS(.v27)],
    products: [.library(name: "MarrowChatModels", targets: ["MarrowChatModels"])],
    targets: [
        .target(name: "MarrowChatModels"),
        .testTarget(name: "MarrowChatModelsTests", dependencies: ["MarrowChatModels"])
    ]
)
