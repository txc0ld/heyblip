// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BlipProtocol",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "BlipProtocol",
            targets: ["BlipProtocol"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "0.12.0"),
    ],
    targets: [
        .target(
            name: "BlipProtocol",
            path: "Sources"
        ),
        .testTarget(
            name: "BlipProtocolTests",
            dependencies: [
                "BlipProtocol",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests"
        ),
    ]
)
