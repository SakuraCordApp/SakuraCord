// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "MediaPipeline",
    platforms: [.macOS(.v27)],
    products: [.library(name: "MediaPipeline", targets: ["MediaPipeline"])],
    dependencies: [
        .package(path: "../SakuraCordModels"),
        .package(path: "../DaveKit"),
        .package(url: "https://github.com/jedisct1/swift-sodium.git", from: "0.9.1")
    ],
    targets: [
        .target(
            name: "MediaPipeline",
            dependencies: [
                "SakuraCordModels",
                "DaveKit",
                .product(name: "Sodium", package: "swift-sodium"),
                .product(name: "Clibsodium", package: "swift-sodium")
            ],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        .testTarget(
            name: "MediaPipelineTests",
            dependencies: ["MediaPipeline"],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        )
    ]
)
