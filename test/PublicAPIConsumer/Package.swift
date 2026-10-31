// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "SwiftSpicePublicAPIConsumer",
    platforms: [
        .macOS(.v26),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "PublicAPIConsumer",
            dependencies: [
                .product(name: "SwiftSpice", package: "libmaspice"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
