// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "SakuraCordModels",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SakuraCordModels", targets: ["SakuraCordModels"])],
    targets: [
        .target(name: "SakuraCordModels"),
        .testTarget(name: "SakuraCordModelsTests", dependencies: ["SakuraCordModels"])
    ]
)
