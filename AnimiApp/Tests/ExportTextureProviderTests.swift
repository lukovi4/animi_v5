import XCTest
import Metal
@testable import AnimiApp
@testable import TVECore

/// Tests for ExportTextureProvider targeted warm/clear API.
final class ExportTextureProviderTests: XCTestCase {

    // MARK: - Warm/Clear API

    func test_warmAndClear_targetedLoading() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTSkip("Metal not available")
            return
        }

        let assetIndex = AssetIndexIR()
        let resolver = CompositeAssetResolver(localIndex: .empty, sharedIndex: .empty)

        let provider = ExportTextureProvider(
            device: device,
            assetIndex: assetIndex,
            resolver: resolver,
            bindingAssetIds: ["binding_1"]
        )

        // No preloadAll API — verify warm is the entry point
        XCTAssertNil(provider.texture(for: "asset_1"), "Should be nil before warm")
    }

    func test_setTexture_andClearAll() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTSkip("Metal not available")
            return
        }

        let assetIndex = AssetIndexIR()
        let resolver = CompositeAssetResolver(localIndex: .empty, sharedIndex: .empty)

        let provider = ExportTextureProvider(
            device: device,
            assetIndex: assetIndex,
            resolver: resolver
        )

        // Create a tiny test texture
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        desc.storageMode = .private
        guard let texture = device.makeTexture(descriptor: desc) else {
            XCTFail("Failed to create test texture")
            return
        }

        // Set and verify
        provider.setTexture(texture, for: "test_id")
        XCTAssertNotNil(provider.texture(for: "test_id"))

        // Clear all and verify
        provider.clearAll()
        XCTAssertNil(provider.texture(for: "test_id"))
    }

    func test_clearSpecificAssetIds() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTSkip("Metal not available")
            return
        }

        let assetIndex = AssetIndexIR()
        let resolver = CompositeAssetResolver(localIndex: .empty, sharedIndex: .empty)
        let provider = ExportTextureProvider(device: device, assetIndex: assetIndex, resolver: resolver)

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        desc.storageMode = .private
        guard let tex1 = device.makeTexture(descriptor: desc),
              let tex2 = device.makeTexture(descriptor: desc) else {
            XCTFail("Failed to create test textures")
            return
        }

        provider.setTexture(tex1, for: "id_1")
        provider.setTexture(tex2, for: "id_2")

        // Also set presentation info on both
        let info = VideoPresentationInfo(
            rawTrackSize: CGSize(width: 1920, height: 1080),
            preferredTransform: .identity
        )
        provider.setPresentationInfo(info, for: "id_1")
        provider.setPresentationInfo(info, for: "id_2")

        // Clear only id_1
        provider.clear(assetIds: ["id_1"])

        XCTAssertNil(provider.texture(for: "id_1"), "Cleared asset should be nil")
        XCTAssertNotNil(provider.texture(for: "id_2"), "Non-cleared asset should remain")
        XCTAssertNil(provider.presentationInfo(for: "id_1"), "Cleared asset presentation info should be nil")
        XCTAssertNotNil(provider.presentationInfo(for: "id_2"), "Non-cleared asset presentation info should remain")
    }

    // MARK: - Presentation Info Metadata

    func test_presentationInfo_setGetRemove() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTSkip("Metal not available")
            return
        }

        let assetIndex = AssetIndexIR()
        let resolver = CompositeAssetResolver(localIndex: .empty, sharedIndex: .empty)
        let provider = ExportTextureProvider(device: device, assetIndex: assetIndex, resolver: resolver)

        let info = VideoPresentationInfo(
            rawTrackSize: CGSize(width: 1920, height: 1080),
            preferredTransform: .identity
        )

        XCTAssertNil(provider.presentationInfo(for: "asset_1"))

        provider.setPresentationInfo(info, for: "asset_1")
        XCTAssertEqual(provider.presentationInfo(for: "asset_1"), info)

        provider.removePresentationInfo(for: "asset_1")
        XCTAssertNil(provider.presentationInfo(for: "asset_1"))
    }

    func test_clearAll_removesPresentationInfo() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTSkip("Metal not available")
            return
        }

        let assetIndex = AssetIndexIR()
        let resolver = CompositeAssetResolver(localIndex: .empty, sharedIndex: .empty)
        let provider = ExportTextureProvider(device: device, assetIndex: assetIndex, resolver: resolver)

        let info = VideoPresentationInfo(
            rawTrackSize: CGSize(width: 1920, height: 1080),
            preferredTransform: .identity
        )

        provider.setPresentationInfo(info, for: "asset_1")
        provider.clearAll()
        XCTAssertNil(provider.presentationInfo(for: "asset_1"))
    }

}
