// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BlipMesh",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "BlipMesh",
            targets: ["BlipMesh"]
        ),
    ],
    dependencies: [
        .package(path: "../BlipProtocol"),
        .package(path: "../BlipCrypto"),
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "0.12.0"),
    ],
    targets: [
        .target(
            name: "BlipMesh",
            dependencies: [
                "BlipProtocol",
                "BlipCrypto",
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "BlipMeshTests",
            dependencies: [
                "BlipMesh",
                "BlipProtocol",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests"
        ),
    ]
)
