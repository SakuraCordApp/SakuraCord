// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "DaveKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(
            name: "DaveKit",
            targets: ["DaveKit"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log", from: "1.16.1"),
        .package(url: "https://github.com/krzyzanowskim/OpenSSL-Package.git", from: "3.6.5000")
    ],
    targets: [
        .target(
            name: "DaveKit",
            dependencies: [
                .target(name: "CLibdave"),
                .product(name: "Logging", package: "swift-log")
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),

        .target(
            name: "CLibdave",
            dependencies: [
                .target(name: "mlspp"),
                .target(name: "bytes"),
                .target(name: "tls_syntax"),
                .product(name: "OpenSSL", package: "OpenSSL-Package")
            ],
            sources: ["libdave/cpp/src"],
            cxxSettings: [
                .headerSearchPath("libdave/cpp/includes"),
                .headerSearchPath("libdave/cpp/src")
            ]
        ),

        .target(
            name: "mlspp",
            dependencies: [
                .target(name: "hpke"),
                .target(name: "bytes"),
                .target(name: "tls_syntax")
            ],
            path: "Sources/CMLS/mlspp",
            sources: ["src"],
            cxxSettings: [
                .define("WITH_PQ")
            ]
        ),

        .target(
            name: "mlspp_namespace",
            path: "Sources/CMLS/namespace",
            publicHeadersPath: "."
        ),

        .target(
            name: "hpke",
            dependencies: [
                .target(name: "mlspp_namespace"),
                .target(name: "bytes"),
                .target(name: "tls_syntax"),
                .target(name: "CJson"),
                .product(name: "OpenSSL", package: "OpenSSL-Package")
            ],
            path: "Sources/CMLS/mlspp/lib/hpke",
            sources: ["src"],
            cxxSettings: [
                .define("WITH_OPENSSL3"),
                // OpenSSL 3.5+ provides ML-KEM. This must match the mlspp target;
                // otherwise its cipher-suite table references algorithms omitted
                // from the HPKE factory and MLS initialization fails.
                .define("WITH_PQ")
            ]
        ),

        .target(
            name: "bytes",
            dependencies: [
                .target(name: "mlspp_namespace"),
                .target(name: "tls_syntax")
            ],
            path: "Sources/CMLS/mlspp/lib/bytes",
            sources: ["src"]
        ),

        .target(
            name: "tls_syntax",
            dependencies: [.target(name: "mlspp_namespace")],
            path: "Sources/CMLS/mlspp/lib/tls_syntax",
            sources: ["src"]
        ),

        .target(name: "CJson"),

        .target(
            name: "DaveKitTestSupport",
            dependencies: ["CLibdave"],
            path: "Tests/DaveKitTestSupport"
        ),
        .testTarget(
            name: "DaveKitTests",
            dependencies: ["DaveKit", "DaveKitTestSupport"],
            swiftSettings: [.interoperabilityMode(.Cxx)],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."])
            ]
        )
    ],
    cxxLanguageStandard: .cxx17
)
