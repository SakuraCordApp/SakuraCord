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
        .executable(name: "discord-sim-profile", targets: ["discord-sim-profile"]),
    ],
    dependencies: [
        .package(url: "https://github.com/facebook/zstd.git", from: "1.5.7"),
        // libdave and MLS++ need OpenSSL 3; the app resolves this same version.
        .package(url: "https://github.com/krzyzanowskim/OpenSSL-Package.git", exact: "3.6.5000"),
    ],
    targets: [
        .target(
            name: "SimulatorKit",
            dependencies: [.product(name: "libzstd", package: "zstd"), "CDave"],
            resources: [.copy("Resources/Shapes"), .copy("Resources/Media"), .copy("Resources/Profiles")]
        ),
        // Upstream libdave v1.3.0/cpp and the MLS++ commit it pins, for simulated DAVE participants.
        // See DESIGN.md (Vendored sources) for what is kept and the SwiftPM-only changes.
        .target(
            name: "CDave",
            dependencies: ["MLSPP", .product(name: "OpenSSL", package: "OpenSSL-Package")],
            sources: ["libdave/cpp/src", "libdave/cpp/test/external_sender.cpp", "libdave/cpp/test/capi/external_sender_wrapper.cpp", "shim"],
            cxxSettings: [.headerSearchPath("libdave/cpp/includes"), .headerSearchPath("libdave/cpp/src"), .define("DAVE_STATIC")]
        ),
        .target(
            name: "MLSPP",
            dependencies: ["MLSHPKE", "MLSBytes", "MLSTLSSyntax"],
            path: "Sources/CMLS/mlspp",
            sources: ["src"],
            cxxSettings: [.define("DISABLE_GREASE")]
        ),
        .target(
            name: "MLSHPKE",
            dependencies: ["MLSNamespace", "MLSBytes", "MLSTLSSyntax", "NlohmannJSON", .product(name: "OpenSSL", package: "OpenSSL-Package")],
            path: "Sources/CMLS/mlspp/lib/hpke",
            sources: ["src"],
            cxxSettings: [.define("WITH_OPENSSL3")]
        ),
        .target(name: "MLSBytes", dependencies: ["MLSNamespace", "MLSTLSSyntax"], path: "Sources/CMLS/mlspp/lib/bytes", sources: ["src"]),
        .target(name: "MLSTLSSyntax", dependencies: ["MLSNamespace"], path: "Sources/CMLS/mlspp/lib/tls_syntax", sources: ["src"]),
        .target(name: "MLSNamespace", path: "Sources/CMLS/namespace", publicHeadersPath: "."),
        .target(name: "NlohmannJSON", path: "Sources/CJSON", sources: ["shim.c"]),
        .executableTarget(name: "discord-simulator", dependencies: ["SimulatorKit"]),
        .executableTarget(name: "discord-simctl", dependencies: ["SimulatorKit"]),
        .executableTarget(name: "discord-sim-parity", dependencies: ["SimulatorKit"]),
        .executableTarget(name: "discord-sim-profile", dependencies: ["SimulatorKit"]),
        .testTarget(name: "SimulatorKitTests", dependencies: ["SimulatorKit", "CDave"]),
    ],
    cxxLanguageStandard: .cxx17
)
