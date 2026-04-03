import XCTest
import Metal
@testable import AnimiApp
@testable import TVECore

/// Tests for DefaultFitResolver — extracted defaultFit resolution logic.
final class DefaultFitResolverTests: XCTestCase {

    // MARK: - Helpers

    @MainActor
    private func makeResources(
        sceneTypeId: String,
        blockId: String,
        defaultFit: FitMode?
    ) -> SceneTypeResourcesCache.Resources {
        let input = MediaInput(
            bindingKey: "media",
            allowedMedia: ["photo"],
            defaultFit: defaultFit
        )
        let block = MediaBlock(
            id: blockId,
            zIndex: 0,
            rect: Rect(x: 0, y: 0, width: 540, height: 960),
            containerClip: .slotRect,
            input: input,
            variants: []
        )
        let canvas = Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 300)
        let scene = Scene(
            schemaVersion: "1.0",
            sceneId: "test",
            canvas: canvas,
            background: nil,
            mediaBlocks: [block]
        )
        let runtime = SceneRuntime(
            scene: scene,
            canvas: canvas,
            blocks: [],
            durationFrames: 300,
            fps: 30
        )
        let compiled = CompiledScene(
            runtime: runtime,
            mergedAssetIndex: AssetIndexIR(),
            pathRegistry: PathRegistry(),
            bindingAssetIds: []
        )
        let resolver = CompositeAssetResolver(localIndex: .empty, sharedIndex: .empty)
        let baseProvider = InMemoryTextureProvider()
        return SceneTypeResourcesCache.Resources(
            sceneTypeId: sceneTypeId,
            compiled: compiled,
            resolver: resolver,
            baseTextureProvider: baseProvider,
            assetSizes: [:],
            pathRegistry: PathRegistry(),
            canvasSize: SizeD(width: 1080, height: 1920),
            fps: 30,
            durationFrames: 300
        )
    }

    @MainActor
    private func makeCache() throws -> SceneTypeResourcesCache {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }
        return SceneTypeResourcesCache(device: device, commandQueue: commandQueue)
    }

    /// Writes a minimal compiled.tve containing one block with `defaultFit: .contain`
    /// into a temporary directory and returns its URL.
    private func writeTVEFixture() throws -> URL {
        let compiled = CompiledScene(
            runtime: SceneRuntime(
                scene: Scene(
                    schemaVersion: "1.0",
                    sceneId: "defaultfit_contain",
                    canvas: Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 300),
                    background: nil,
                    mediaBlocks: [
                        MediaBlock(
                            id: "block_01",
                            zIndex: 0,
                            rect: Rect(x: 0, y: 0, width: 540, height: 960),
                            containerClip: .slotRect,
                            input: MediaInput(
                                bindingKey: "media",
                                allowedMedia: ["photo"],
                                defaultFit: .contain
                            ),
                            variants: []
                        )
                    ]
                ),
                canvas: Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 300),
                blocks: [],
                durationFrames: 300,
                fps: 30
            ),
            mergedAssetIndex: AssetIndexIR(),
            pathRegistry: PathRegistry(),
            bindingAssetIds: []
        )
        let payload = CompiledScenePayload(
            compiled: compiled,
            templateId: "defaultfit_contain",
            templateRevision: 1,
            engineVersion: TVECore.version
        )

        let encoder = JSONEncoder()
        let payloadData = try encoder.encode(payload)

        // Build .tve binary: header (18 bytes) + JSON payload
        var data = Data()
        data.reserveCapacity(18 + payloadData.count)

        // Magic: "TVE1"
        data.append(contentsOf: [0x54, 0x56, 0x45, 0x31])
        // Format version (UInt16 LE)
        appendLE(&data, UInt16(1))
        // Header length (UInt16 LE) — 18 bytes (v1 with schema)
        appendLE(&data, UInt16(18))
        // Payload length (UInt32 LE)
        appendLE(&data, UInt32(payloadData.count))
        // Engine version hash (UInt32 LE)
        appendLE(&data, engineVersionHash(TVECore.version))
        // IR schema version (UInt16 LE)
        appendLE(&data, CompiledPackageConstants.currentIRSchemaVersion)
        // JSON payload
        data.append(payloadData)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("defaultfit_contain_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent("compiled.tve"))
        // Create empty images/ directory (required by LocalAssetsIndex)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("images"),
            withIntermediateDirectories: true
        )
        return dir
    }

    private func appendLE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    // MARK: - Tests

    /// Cache hit with defaultFit: .contain returns .contain (not fallback .cover).
    @MainActor
    func test_cacheHit_returnsTemplateFit() throws {
        let cache = try makeCache()
        let resources = makeResources(sceneTypeId: "scene-A", blockId: "block_01", defaultFit: .contain)
        cache.addToCache(resources)

        let fit = DefaultFitResolver.resolveFromCache(sceneTypeId: "scene-A", blockId: "block_01", cache: cache)
        XCTAssertEqual(fit, .contain)
    }

    /// Empty cache with no sceneURLProvider falls back to .cover.
    @MainActor
    func test_cacheMiss_noPreloadProvider_returnsCover() async throws {
        let cache = try makeCache()

        let fit = await DefaultFitResolver.resolve(sceneTypeId: "scene-missing", blockId: "block_01", cache: cache)
        XCTAssertEqual(fit, .cover)
    }

    /// Cache has resources but blockId doesn't match — returns nil (sync) / .cover (async).
    @MainActor
    func test_unknownBlockId_returnsCover() async throws {
        let cache = try makeCache()
        let resources = makeResources(sceneTypeId: "scene-A", blockId: "block_01", defaultFit: .contain)
        cache.addToCache(resources)

        let syncFit = DefaultFitResolver.resolveFromCache(sceneTypeId: "scene-A", blockId: "block_99", cache: cache)
        XCTAssertNil(syncFit)

        let asyncFit = await DefaultFitResolver.resolve(sceneTypeId: "scene-A", blockId: "block_99", cache: cache)
        XCTAssertEqual(asyncFit, .cover)
    }

    /// MediaBlock exists but defaultFit is nil — returns nil (sync) / .cover (async).
    @MainActor
    func test_defaultFitNil_returnsCover() async throws {
        let cache = try makeCache()
        let resources = makeResources(sceneTypeId: "scene-A", blockId: "block_01", defaultFit: nil)
        cache.addToCache(resources)

        let syncFit = DefaultFitResolver.resolveFromCache(sceneTypeId: "scene-A", blockId: "block_01", cache: cache)
        XCTAssertNil(syncFit)

        let asyncFit = await DefaultFitResolver.resolve(sceneTypeId: "scene-A", blockId: "block_01", cache: cache)
        XCTAssertEqual(asyncFit, .cover)
    }

    /// Integration: empty cache → preloadMetadata succeeds → returns template fit.
    /// Proves the full cold-cache path end-to-end with real SceneTypeResourcesCache + real .tve.
    @MainActor
    func test_cacheMiss_preloadSuccess_returnsTemplateFit() async throws {
        let cache = try makeCache()

        // Write a temporary compiled.tve with defaultFit: .contain
        let fixtureURL = try writeTVEFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        cache.sceneURLProvider = { sceneTypeId in
            sceneTypeId == "defaultfit_contain" ? fixtureURL : nil
        }

        let fit = await DefaultFitResolver.resolve(
            sceneTypeId: "defaultfit_contain",
            blockId: "block_01",
            cache: cache
        )
        XCTAssertEqual(fit, .contain, "Cold-cache resolve should return .contain from fixture, not fallback .cover")
    }
}
