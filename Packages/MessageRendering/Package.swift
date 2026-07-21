// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "MessageRendering",
    platforms: [.macOS(.v27)],
    products: [.library(name: "MessageRendering", targets: ["MessageRendering"])],
    dependencies: [.package(path: "../SakuraCordModels")],
    targets: [
        .target(name: "MessageRendering", dependencies: ["SakuraCordModels"]),
        .testTarget(name: "MessageRenderingTests", dependencies: ["MessageRendering"])
    ]
)
