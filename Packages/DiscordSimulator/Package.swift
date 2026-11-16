// swift-tools-version: 6.4
import PackageDescription

// A local stand-in for Discord's REST, Gateway, CDN and upload hosts. It is
// built from captured wire data and must not depend on DiscordProtocol.
let package = Package(
    name: "DiscordSimulator",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "SimulatorKit", targets: ["SimulatorKit"]),
        .executable(name: "discord-simulator", targets: ["discord-simulator"]),
        .executable(name: "discord-simctl", targets: ["discord-simctl"]),
        .executable(name: "discord-sim-parity", targets: ["discord-sim-parity"]),
    ],
    dependencies: [
        .package(url: "https://github.com/facebook/zstd.git", from: "1.5.7"),
    ],
    targets: [
        .target(
            name: "SimulatorKit",
            dependencies: [.product(name: "libzstd", package: "zstd")],
            resources: [.copy("Resources/Shapes"), .copy("Resources/Media")]
        ),
        .executableTarget(name: "discord-simulator", dependencies: ["SimulatorKit"]),
        .executableTarget(name: "discord-simctl", dependencies: ["SimulatorKit"]),
        .executableTarget(name: "discord-sim-parity", dependencies: ["SimulatorKit"]),
        .testTarget(name: "SimulatorKitTests", dependencies: ["SimulatorKit"]),
    ]
)
