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
        ),
        .library(
            name: "TVECompilerCore",
            targets: ["TVECompilerCore"]
        ),
        .executable(
            name: "TVETemplateCompiler",
            targets: ["TVETemplateCompiler"]
        )
    ],
    targets: [
        .target(
            name: "TVECore",
            dependencies: [],
            path: "Sources/TVECore",
            resources: [
                .process("MetalRenderer/Shaders")
            ]
        ),
        .target(
            name: "TVECompilerCore",
            dependencies: ["TVECore"],
            path: "Sources/TVECompilerCore"
        ),
        .executableTarget(
            name: "TVETemplateCompiler",
            dependencies: ["TVECompilerCore"],
            path: "Tools/TVETemplateCompiler"
        ),
        // NOTE: TVECoreTests temporarily depends on TVECompilerCore (variant A from review.md)
        // TODO: Split into TVECoreTests + TVECompilerCoreTests (variant B) in separate task
        .testTarget(
            name: "TVECoreTests",
            dependencies: ["TVECore", "TVECompilerCore"],
            path: "Tests/TVECoreTests",
            resources: [
                .copy("Resources")
            ]
        )
    ]
)
