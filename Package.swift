// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "SwiftSpice",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SwiftSpice", targets: ["SwiftSpice"])],
    targets: [
        .binaryTarget(name: "CSpiceZig", path: "pkg/apple/artifacts/CSpiceZig.xcframework"),
        .binaryTarget(name: "CSpiceQUIC", path: "pkg/apple/artifacts/CSpiceQUIC.xcframework"),
        .binaryTarget(name: "CTurboJPEG", path: "pkg/apple/artifacts/CTurboJPEG.xcframework"),
        .binaryTarget(name: "CUSBRedir", path: "pkg/apple/artifacts/CUSBRedir.xcframework"),
        .target(
            name: "SwiftSpice",
            dependencies: ["CSpiceZig", "CTurboJPEG", "CSpiceQUIC", "CUSBRedir"],
            path: "bindings/swift/SpiceZigSwift",
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("MetalKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("AVFAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AppKit"),
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Foundation"),
                .linkedFramework("Network"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalPerformanceShaders"),
                .linkedLibrary("z"),
            ],
            plugins: ["CompileMetalShaders"]
        ),
        .plugin(name: "CompileMetalShaders", capability: .buildTool(), path: "bindings/swift/Plugins/CompileMetalShaders", exclude: ["compile-metal.sh"]),
        .testTarget(name: "SpiceZigSwiftTests", dependencies: ["SwiftSpice"], path: "test/swift"),
    ],
    swiftLanguageModes: [.v6]
)
