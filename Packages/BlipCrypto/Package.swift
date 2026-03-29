// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BlipCrypto",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "BlipCrypto",
            targets: ["BlipCrypto"]
        ),
    ],
    dependencies: [
        .package(path: "../BlipProtocol"),
        .package(url: "https://github.com/jedisct1/swift-sodium.git", from: "0.9.1"),
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "0.12.0"),
    ],
    targets: [
        .target(
            name: "BlipCrypto",
            dependencies: [
                "BlipProtocol",
                .product(name: "Sodium", package: "swift-sodium"),
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "BlipCryptoTests",
            dependencies: [
                "BlipCrypto",
                "BlipProtocol",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests"
        ),
    ]
)
