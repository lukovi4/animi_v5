import XCTest
import Metal
@testable import TVECore

// MARK: - TT-07: Texture Provider Split Tests

/// Tests for TT-07 texture provider split: immutable base vs mutable overlay semantics.
///
/// Verifies:
/// - `ScenePackageBaseTextureProvider` does NOT conform to `MutableTextureProvider`
/// - Mutable `ScenePackageTextureProvider` internal base/overlay split with real preloaded textures
/// - `LayeredTextureProvider` overlay precedence and remove semantics
final class ScenePackageTextureProviderSplitTests: XCTestCase {

    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!

    /// URL to example_4blocks fixture images directory.
    private var fixtureImagesURL: URL? {
        Bundle.module.url(
            forResource: "scene",
            withExtension: "json",
            subdirectory: "Resources/example_4blocks"
        )?.deletingLastPathComponent().appendingPathComponent("images")
    }

    override func setUp() {
        super.setUp()
        device = MTLCreateSystemDefaultDevice()
        guard device != nil else { return }
        commandQueue = device.makeCommandQueue()
    }

    // MARK: - Helpers

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

    /// Creates a mutable provider with real preloaded textures from fixture.
    /// Returns (provider, preloaded asset ID) or skips if fixture unavailable.
    private func makeMutableProviderWithPreloadedFixture() throws -> (ScenePackageTextureProvider, String) {
        let imagesURL = try XCTUnwrap(fixtureImagesURL, "Fixture images not found")

        let localIndex = try LocalAssetsIndex(imagesRootURL: imagesURL)
        let sharedIndex = SharedAssetsIndex.empty
        let resolver = CompositeAssetResolver(localIndex: localIndex, sharedIndex: sharedIndex)

        // Asset index: map "img_1" asset ID to basename "img_1" (matches img_1.png in fixture)
        let assetId = "test_anim|img_1"
        let index = AssetIndexIR(
            byId: [assetId: "images/img_1.png"],
            sizeById: [assetId: AssetSize(width: 100, height: 100)],
            basenameById: [assetId: "img_1"]
        )

        let provider = ScenePackageTextureProvider(
            device: device,
            assetIndex: index,
            resolver: resolver
        )
        provider.preloadAll(commandQueue: commandQueue)

        // Verify preload actually loaded the texture
        let stats = try XCTUnwrap(provider.lastPreloadStats)
        XCTAssertGreaterThanOrEqual(stats.loadedCount, 1, "Fixture preload must load at least 1 texture")

        return (provider, assetId)
    }

    /// Creates a base provider with real preloaded textures from fixture.
    private func makeBaseProviderWithPreloadedFixture() throws -> (ScenePackageBaseTextureProvider, String) {
        let imagesURL = try XCTUnwrap(fixtureImagesURL, "Fixture images not found")

        let localIndex = try LocalAssetsIndex(imagesRootURL: imagesURL)
        let sharedIndex = SharedAssetsIndex.empty
        let resolver = CompositeAssetResolver(localIndex: localIndex, sharedIndex: sharedIndex)

        let assetId = "test_anim|img_1"
        let index = AssetIndexIR(
            byId: [assetId: "images/img_1.png"],
            sizeById: [assetId: AssetSize(width: 100, height: 100)],
            basenameById: [assetId: "img_1"]
        )

        let provider = ScenePackageBaseTextureProvider(
            device: device,
            assetIndex: index,
            resolver: resolver
        )
        provider.preloadAll(commandQueue: commandQueue)

        let stats = try XCTUnwrap(provider.lastPreloadStats)
        XCTAssertGreaterThanOrEqual(stats.loadedCount, 1, "Fixture preload must load at least 1 texture")

        return (provider, assetId)
    }

    // MARK: - 1. ScenePackageBaseTextureProvider is NOT MutableTextureProvider

    func testBaseProvider_doesNotConformToMutableTextureProvider() throws {
        try XCTSkipIf(device == nil, "Metal not available")

        let resolver = CompositeAssetResolver(localIndex: .empty, sharedIndex: .empty)
        let baseProvider = ScenePackageBaseTextureProvider(
            device: device,
            assetIndex: AssetIndexIR(),
            resolver: resolver
        )

        let _: TextureProvider = baseProvider
        let asMutable = baseProvider as? MutableTextureProvider
        XCTAssertNil(asMutable, "ScenePackageBaseTextureProvider must NOT conform to MutableTextureProvider")
    }

    // MARK: - 2. Mutable ScenePackageTextureProvider: internal base/overlay split

    /// TT-07: preloaded base texture exists, setTexture overrides it, removeTexture reveals it.
    /// Tests the actual ScenePackageTextureProvider (not LayeredTextureProvider).
    func testMutableProvider_setTextureOverridesPreloadedBase() throws {
        try XCTSkipIf(device == nil, "Metal not available")

        let (provider, assetId) = try makeMutableProviderWithPreloadedFixture()

        // Base texture is preloaded and visible
        let baseTexture = provider.texture(for: assetId)
        XCTAssertNotNil(baseTexture, "Preloaded base texture must be available")

        // Inject overlay texture
        let injectedTexture = try XCTUnwrap(makeTexture(label: "injected"))
        provider.setTexture(injectedTexture, for: assetId)

        // Overlay takes precedence
        let result = provider.texture(for: assetId)
        XCTAssertTrue(result === injectedTexture, "setTexture must override preloaded base texture")
        XCTAssertFalse(result === baseTexture, "Injected texture must be different from base")
    }

    /// TT-07: removeTexture on mutable provider reveals the preloaded base texture.
    /// This is the core contract: remove only clears overlay, base stays intact.
    func testMutableProvider_removeTextureRevealsPreloadedBase() throws {
        try XCTSkipIf(device == nil, "Metal not available")

        let (provider, assetId) = try makeMutableProviderWithPreloadedFixture()

        // Capture the preloaded base texture
        let baseTexture = try XCTUnwrap(provider.texture(for: assetId))

        // Inject overlay
        let injectedTexture = try XCTUnwrap(makeTexture(label: "injected"))
        provider.setTexture(injectedTexture, for: assetId)
        XCTAssertTrue(provider.texture(for: assetId) === injectedTexture)

        // Remove overlay — base must be revealed, NOT nil
        provider.removeTexture(for: assetId)
        let afterRemove = provider.texture(for: assetId)
        XCTAssertTrue(afterRemove === baseTexture,
                       "removeTexture must reveal preloaded base texture, not return nil")
    }

    // MARK: - 3. LayeredTextureProvider invariants

    func testLayered_overlayHasPriority() throws {
        try XCTSkipIf(device == nil, "Metal not available")

        let baseTexture = try XCTUnwrap(makeTexture(label: "base"))
        let overlayTexture = try XCTUnwrap(makeTexture(label: "overlay"))

        let base = InMemoryTextureProvider()
        base.setTexture(baseTexture, for: "asset_1")

        let overlay = InMemoryTextureProvider()
        overlay.setTexture(overlayTexture, for: "asset_1")

        let layered = LayeredTextureProvider(base: base, overlay: overlay)
        XCTAssertTrue(layered.texture(for: "asset_1") === overlayTexture, "Overlay must take priority over base")
    }

    func testLayered_removeRevealsBase() throws {
        try XCTSkipIf(device == nil, "Metal not available")

        let baseTexture = try XCTUnwrap(makeTexture(label: "base"))
        let overlayTexture = try XCTUnwrap(makeTexture(label: "overlay"))

        let base = InMemoryTextureProvider()
        base.setTexture(baseTexture, for: "asset_1")

        let overlay = InMemoryTextureProvider()
        overlay.setTexture(overlayTexture, for: "asset_1")

        let layered = LayeredTextureProvider(base: base, overlay: overlay)

        layered.removeTexture(for: "asset_1")
        XCTAssertTrue(layered.texture(for: "asset_1") === baseTexture,
                       "After remove, base texture must be visible")
    }

    func testLayered_neverMutatesBase() throws {
        try XCTSkipIf(device == nil, "Metal not available")

        let baseTexture = try XCTUnwrap(makeTexture(label: "base"))
        let injectedTexture = try XCTUnwrap(makeTexture(label: "injected"))

        let base = InMemoryTextureProvider()
        base.setTexture(baseTexture, for: "asset_1")

        let overlay = InMemoryTextureProvider()
        let layered = LayeredTextureProvider(base: base, overlay: overlay)

        layered.setTexture(injectedTexture, for: "asset_1")
        XCTAssertTrue(base.texture(for: "asset_1") === baseTexture,
                       "setTexture on layered must not mutate base provider")

        layered.removeTexture(for: "asset_1")
        XCTAssertTrue(base.texture(for: "asset_1") === baseTexture,
                       "removeTexture on layered must not mutate base provider")
    }

    func testLayered_bindingAssetFlow() throws {
        try XCTSkipIf(device == nil, "Metal not available")

        let userMediaTexture = try XCTUnwrap(makeTexture(label: "user_media"))

        let base = InMemoryTextureProvider()
        let overlay = InMemoryTextureProvider()
        let layered = LayeredTextureProvider(base: base, overlay: overlay)

        // Before injection: nil (binding asset has no file)
        XCTAssertNil(layered.texture(for: "binding_asset"))

        // After overlay injection: user media visible
        overlay.setTexture(userMediaTexture, for: "binding_asset")
        XCTAssertTrue(layered.texture(for: "binding_asset") === userMediaTexture)

        // After remove: back to nil
        layered.removeTexture(for: "binding_asset")
        XCTAssertNil(layered.texture(for: "binding_asset"))
    }
}
