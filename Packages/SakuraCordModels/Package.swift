// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "SakuraCordModels",
    platforms: [.macOS(.v27)],
    products: [.library(name: "SakuraCordModels", targets: ["SakuraCordModels"])],
    targets: [
        .target(name: "SakuraCordModels"),
        .testTarget(name: "SakuraCordModelsTests", dependencies: ["SakuraCordModels"])
    ]
)
