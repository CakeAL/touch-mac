// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TouchBridgeViewer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "TouchBridgeViewer", targets: ["TouchBridgeViewer"])
    ],
    targets: [
        .executableTarget(
            name: "TouchBridgeViewer",
            path: "Sources/TouchBridgeViewer",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreFoundation")
            ]
        )
    ]
)
