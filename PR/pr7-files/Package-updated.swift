// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TVECore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "TVECore",
            targets: ["TVECore"]
        )
    ],
    targets: [
        .target(
            name: "TVECore",
            dependencies: [],
            path: "Sources/TVECore",
            exclude: ["MetalRenderer/Shaders/QuadShaders.metal"]
        ),
        .testTarget(
            name: "TVECoreTests",
            dependencies: ["TVECore"],
            path: "Tests/TVECoreTests",
            resources: [
                .copy("Resources")
            ]
        )
    ]
)
