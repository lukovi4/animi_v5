import XCTest
import Metal
@testable import AnimiApp
@testable import TVECore

// MARK: - TT-07: Scene Type Resources Cache Provider Split Tests

/// Tests for TT-07: verifies that SceneTypeResourcesCache uses immutable base provider
/// and that per-instance overlay isolation works correctly.
///
/// Integration tests use real fixture scene via `sceneURLProvider + preload(sceneTypeId:)`.
/// Unit tests use manually assembled Resources for overlay isolation verification.
final class SceneTypeResourcesCacheProviderSplitTests: XCTestCase {

    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!

    override func setUp() {
        super.setUp()
        device = MTLCreateSystemDefaultDevice()
        guard device != nil else { return }
        commandQueue = device.makeCommandQueue()
    }

    // MARK: - Fixture Access

    /// Resolves compiled fixture scene URL from project tree.
    /// Returns nil if fixture is not available in the test environment.
    private var fixtureSceneURL: URL? {
        // Navigate from this test file up to AnimiApp/Resources/Scenes/example_4blocks
        let testFile = URL(fileURLWithPath: #filePath)
        // .../AnimiApp/Tests/ThisFile.swift → .../AnimiApp
        let animiAppDir = testFile
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // AnimiApp/
        let fixtureURL = animiAppDir
            .appendingPathComponent("Resources")
            .appendingPathComponent("Scenes")
            .appendingPathComponent("example_4blocks")

        // Verify compiled.tve exists
        let compiledFile = fixtureURL.appendingPathComponent("compiled.tve")
        guard FileManager.default.fileExists(atPath: compiledFile.path) else {
            return nil
        }
        return fixtureURL
    }

    // MARK: - Helpers

    @MainActor
    private func makeMinimalResources(
        sceneTypeId: String = "test-scene-type",
        durationFrames: Int = 100,
        fps: Int = 30
    ) -> SceneTypeResourcesCache.Resources {
        let canvas = Canvas(width: 1080, height: 1920, fps: fps, durationFrames: durationFrames)
        let scene = Scene(
            schemaVersion: "1.0",
            sceneId: "test-scene",
            canvas: canvas,
            background: nil,
            mediaBlocks: []
        )
        let runtime = SceneRuntime(
            scene: scene,
            canvas: canvas,
            blocks: [],
            durationFrames: durationFrames,
            fps: fps
        )
        let bindingAssetIds: Set<String> = ["binding_asset"]
        let compiled = CompiledScene(
            runtime: runtime,
            mergedAssetIndex: AssetIndexIR(),
            pathRegistry: PathRegistry(),
            bindingAssetIds: bindingAssetIds
        )
        let resolver = CompositeAssetResolver(localIndex: .empty, sharedIndex: .empty)

        let baseProvider = ScenePackageBaseTextureProvider(
            device: device,
            assetIndex: compiled.mergedAssetIndex,
            resolver: resolver,
            bindingAssetIds: bindingAssetIds
        )
        baseProvider.preloadAll(commandQueue: commandQueue)

        return SceneTypeResourcesCache.Resources(
            sceneTypeId: sceneTypeId,
            compiled: compiled,
            resolver: resolver,
            baseTextureProvider: baseProvider,
            assetSizes: [:],
            pathRegistry: PathRegistry(),
            canvasSize: SizeD(width: Double(canvas.width), height: Double(canvas.height)),
            fps: fps,
            durationFrames: durationFrames
        )
    }

    private func makeTexture(label: String? = nil) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 1, height: 1,
            mipmapped: false
        )
        desc.usage = .shaderRead
        desc.storageMode = .shared
        let tex = device.makeTexture(descriptor: desc)
        tex?.label = label
        return tex
    }

    // MARK: - 1. Integration: preload(sceneTypeId:) produces immutable base provider

    @MainActor
    func testPreload_producesImmutableBaseProvider() async throws {
        try XCTSkipIf(device == nil, "Metal not available")
        guard let sceneURL = fixtureSceneURL else {
            throw XCTSkip("Fixture scene 'example_4blocks' not found at AnimiApp/Resources/Scenes/example_4blocks")
        }

        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        cache.sceneURLProvider = { sceneTypeId in
            guard sceneTypeId == "example_4blocks" else { return nil }
            return sceneURL
        }

        let resources = try await cache.preload(sceneTypeId: "example_4blocks")

        // Core assertion: base provider from production preload path is NOT MutableTextureProvider
        let asMutable = resources.baseTextureProvider as? MutableTextureProvider
        XCTAssertNil(asMutable,
                     "preload(sceneTypeId:) must produce immutable base provider (not MutableTextureProvider)")
    }

    // MARK: - 2. Integration: repeated preload returns same cached provider object

    @MainActor
    func testPreload_repeatedCallReturnsSameCachedProvider() async throws {
        try XCTSkipIf(device == nil, "Metal not available")
        guard let sceneURL = fixtureSceneURL else {
            throw XCTSkip("Fixture scene 'example_4blocks' not found")
        }

        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        cache.sceneURLProvider = { sceneTypeId in
            guard sceneTypeId == "example_4blocks" else { return nil }
            return sceneURL
        }

        let first = try await cache.preload(sceneTypeId: "example_4blocks")
        let second = try await cache.preload(sceneTypeId: "example_4blocks")

        let baseFirst = first.baseTextureProvider as AnyObject
        let baseSecond = second.baseTextureProvider as AnyObject
        XCTAssertTrue(baseFirst === baseSecond,
                       "Repeated preload must return same cached base provider object")
    }

    // MARK: - 3. Unit: base provider from manual Resources is NOT MutableTextureProvider

    @MainActor
    func testCachedBaseProvider_doesNotConformToMutableTextureProvider() throws {
        try XCTSkipIf(device == nil, "Metal not available")

        let resources = makeMinimalResources()
        let asMutable = resources.baseTextureProvider as? MutableTextureProvider
        XCTAssertNil(asMutable,
                     "Resources.baseTextureProvider must NOT be MutableTextureProvider")
    }

    // MARK: - 4. Unit: two runtimes share base, have different overlays

    @MainActor
    func testTwoRuntimes_shareBaseProvider() throws {
        try XCTSkipIf(device == nil, "Metal not available")

        let resources = makeMinimalResources()

        let runtimeA = SceneInstanceRuntime(
            sceneInstanceId: UUID(),
            resources: resources,
            device: device,
            commandQueue: commandQueue
        )

        let runtimeB = SceneInstanceRuntime(
            sceneInstanceId: UUID(),
            resources: resources,
            device: device,
            commandQueue: commandQueue
        )

        // Base providers are the SAME object (shared via Resources)
        let baseA = runtimeA.resources.baseTextureProvider as AnyObject
        let baseB = runtimeB.resources.baseTextureProvider as AnyObject
        XCTAssertTrue(baseA === baseB, "Both runtimes must share the same base provider object")

        // Layered providers are different (per-instance)
        XCTAssertFalse(runtimeA.layeredTextureProvider === runtimeB.layeredTextureProvider,
                        "Each runtime must have its own LayeredTextureProvider")

        // Overlay providers are different (per-instance)
        let overlayA = runtimeA.overlayTextureProvider as AnyObject
        let overlayB = runtimeB.overlayTextureProvider as AnyObject
        XCTAssertFalse(overlayA === overlayB, "Each runtime must have its own overlay provider")
    }

    // MARK: - 5. Unit: overlay isolation between instances

    @MainActor
    func testTwoRuntimes_overlayIsolation() throws {
        try XCTSkipIf(device == nil, "Metal not available")

        let resources = makeMinimalResources()

        let runtimeA = SceneInstanceRuntime(
            sceneInstanceId: UUID(),
            resources: resources,
            device: device,
            commandQueue: commandQueue
        )

        let runtimeB = SceneInstanceRuntime(
            sceneInstanceId: UUID(),
            resources: resources,
            device: device,
            commandQueue: commandQueue
        )

        let textureA = try XCTUnwrap(makeTexture(label: "media_A"))

        // Inject into runtime A's overlay
        runtimeA.overlayTextureProvider.setTexture(textureA, for: "binding_asset")

        // Runtime A sees it
        XCTAssertTrue(runtimeA.layeredTextureProvider.texture(for: "binding_asset") === textureA,
                       "Runtime A should see injected texture")

        // Runtime B does NOT see it
        XCTAssertNil(runtimeB.layeredTextureProvider.texture(for: "binding_asset"),
                     "Runtime B must NOT see texture injected into runtime A's overlay")
    }

    // MARK: - 6. Unit: cache deduplication via addToCache

    @MainActor
    func testCache_returnsSameResourcesForSameSceneTypeId() throws {
        try XCTSkipIf(device == nil, "Metal not available")

        let cache = SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
        let resources = makeMinimalResources(sceneTypeId: "shared-type")
        cache.addToCache(resources)

        let first = cache.resources(for: "shared-type")
        let second = cache.resources(for: "shared-type")

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)

        let baseFirst = first!.baseTextureProvider as AnyObject
        let baseSecond = second!.baseTextureProvider as AnyObject
        XCTAssertTrue(baseFirst === baseSecond, "Repeated cache access must return same base provider object")
    }
}
