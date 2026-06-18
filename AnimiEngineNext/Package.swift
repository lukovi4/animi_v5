// swift-tools-version: 5.9

import PackageDescription

// AnimiEngineNext — isolated next-generation video engine package.
//
// Per Task-001 plan (Revision 3) and ADR-001:
//   * Zero product dependencies — does NOT depend on TVECore and MUST NOT import AnimiApp.
//   * Minimum iOS 18 (intentionally higher than TVECore's iOS 16 floor), declared as
//     version strings — NOT the `.v18`/`.v15` enum constants.
//   * `AnimiEngineTestSupport` is a plain test/dev-only target, never exposed as a product.
let package = Package(
    name: "AnimiEngineNext",
    platforms: [
        .iOS("18.0"),
        .macOS("15.0")
    ],
    products: [
        .library(
            name: "AnimiEngineNext",
            targets: ["AnimiEngineNext"]
        ),
        .library(
            name: "AnimiEngineDiagnostics",
            targets: ["AnimiEngineDiagnostics"]
        ),
        // Task-002: the deterministic functional core. Independent of AnimiEngineNext,
        // diagnostics, app code, AVFoundation, and all IO (ADR-001, Task-002 plan §3).
        .library(
            name: "AnimiEngineCore",
            targets: ["AnimiEngineCore"]
        ),
        // Task-003 §4.1 — the four new production targets are exposed as library products.
        // `AnimiEngineRenderTestSupport` is intentionally NOT a product (§4.2).
        .library(
            name: "AnimiEngineRenderModel",
            targets: ["AnimiEngineRenderModel"]
        ),
        .library(
            name: "AnimiEngineTemplateAdapter",
            targets: ["AnimiEngineTemplateAdapter"]
        ),
        .library(
            name: "AnimiEngineRenderGraph",
            targets: ["AnimiEngineRenderGraph"]
        ),
        .library(
            name: "AnimiEngineMetalRender",
            targets: ["AnimiEngineMetalRender"]
        )
    ],
    targets: [
        .target(
            name: "AnimiEngineNext",
            dependencies: [],
            path: "Sources/AnimiEngineNext"
        ),
        // Task-002: pure project/time/geometry/timeline/evaluator core. No dependencies.
        .target(
            name: "AnimiEngineCore",
            dependencies: [],
            path: "Sources/AnimiEngineCore"
        ),
        // Task-003 §10.1 corrective exception: a private C shim for secure descriptor-relative
        // supplemental-artifact creation. Swift's Darwin overlay marks variadic open/openat
        // unavailable, so the mandated openat/O_NOFOLLOW/O_EXCL write needs C. Narrowly scoped to one
        // operation; intentionally NOT a package product.
        .target(
            name: "AnimiEngineDiagnosticsCShim",
            path: "Sources/AnimiEngineDiagnosticsCShim"
        ),
        .target(
            name: "AnimiEngineDiagnostics",
            dependencies: ["AnimiEngineNext", "AnimiEngineDiagnosticsCShim"],
            path: "Sources/AnimiEngineDiagnostics"
        ),
        // Non-public dev/test support target. Intentionally NOT listed under `products`.
        // Task-002: gains a dependency on AnimiEngineCore for fixtures only.
        .target(
            name: "AnimiEngineTestSupport",
            dependencies: ["AnimiEngineNext", "AnimiEngineDiagnostics", "AnimiEngineCore"],
            path: "Sources/AnimiEngineTestSupport"
        ),

        // MARK: - Task-003 production targets (§4.1)

        // Immutable, Sendable render-material values. Depends only on the functional core.
        .target(
            name: "AnimiEngineRenderModel",
            dependencies: ["AnimiEngineCore"],
            path: "Sources/AnimiEngineRenderModel"
        ),
        // Compiled .tve decoding and canonical conversion. Produces model values; consumes Core +
        // RenderModel. MUST NOT import TVECore/TVECompilerCore/AnimiApp (§4.1).
        .target(
            name: "AnimiEngineTemplateAdapter",
            dependencies: ["AnimiEngineCore", "AnimiEngineRenderModel"],
            path: "Sources/AnimiEngineTemplateAdapter"
        ),
        // Pure deterministic RenderGraph compilation. No IO, no Metal. Depends on Core + RenderModel
        // and NOT on the adapter (§4.1, D3-04).
        .target(
            name: "AnimiEngineRenderGraph",
            dependencies: ["AnimiEngineCore", "AnimiEngineRenderModel"],
            path: "Sources/AnimiEngineRenderGraph"
        ),
        // Stateful Metal executor. Depends on RenderModel + RenderGraph only; does not load templates
        // or resolve files (§4.1). Step 10 (R2): the Metal shaders are bundled via .process. The build
        // pipeline decides the on-disk form — `swift build` copies `AnimiEngineRender.metal` as source,
        // whereas Xcode compiles it into a `default.metallib`. `BundledShaderLibraryLoader` loads whichever
        // is present from `Bundle.module` (plan §9.3, device-gate finding).
        .target(
            name: "AnimiEngineMetalRender",
            dependencies: ["AnimiEngineRenderModel", "AnimiEngineRenderGraph"],
            path: "Sources/AnimiEngineMetalRender",
            resources: [.process("Shaders")]
        ),

        // MARK: - Task-003 non-product support target (§4.2)

        // Render evidence/comparison/reference support. Intentionally NOT a package product.
        .target(
            name: "AnimiEngineRenderTestSupport",
            dependencies: [
                "AnimiEngineCore",
                "AnimiEngineRenderModel",
                "AnimiEngineTemplateAdapter",
                "AnimiEngineRenderGraph",
                "AnimiEngineMetalRender",
                "AnimiEngineDiagnostics",
                "AnimiEngineTestSupport"
            ],
            path: "Sources/AnimiEngineRenderTestSupport"
        ),
        .testTarget(
            name: "AnimiEngineNextTests",
            dependencies: [
                "AnimiEngineNext",
                "AnimiEngineDiagnostics",
                "AnimiEngineTestSupport"
            ],
            path: "Tests/AnimiEngineNextTests"
        ),
        // Task-002: functional-core tests.
        .testTarget(
            name: "AnimiEngineCoreTests",
            dependencies: [
                "AnimiEngineCore",
                "AnimiEngineTestSupport"
            ],
            path: "Tests/AnimiEngineCoreTests"
        ),

        // MARK: - Task-003 test targets (§4.3)

        // The dependency-boundary suite imports all four production modules to prove the allowed
        // graph links and scans sources/manifest for forbidden tokens (G1).
        .testTarget(
            name: "AnimiEngineTemplateAdapterTests",
            dependencies: [
                "AnimiEngineCore",
                "AnimiEngineRenderModel",
                "AnimiEngineTemplateAdapter",
                "AnimiEngineRenderGraph",
                "AnimiEngineMetalRender",
                "AnimiEngineRenderTestSupport"
            ],
            path: "Tests/AnimiEngineTemplateAdapterTests"
        ),
        .testTarget(
            name: "AnimiEngineRenderGraphTests",
            dependencies: [
                "AnimiEngineCore",
                "AnimiEngineRenderModel",
                "AnimiEngineRenderGraph",
                "AnimiEngineTemplateAdapter",
                "AnimiEngineRenderTestSupport"
            ],
            path: "Tests/AnimiEngineRenderGraphTests"
        ),
        .testTarget(
            name: "AnimiEngineMetalRenderTests",
            dependencies: [
                "AnimiEngineRenderModel",
                "AnimiEngineRenderGraph",
                "AnimiEngineMetalRender",
                "AnimiEngineRenderTestSupport"
            ],
            path: "Tests/AnimiEngineMetalRenderTests"
        )
    ]
)
