import XCTest
import Metal
import simd
@testable import TVECore

final class VideoPresentationInfoTests: XCTestCase {

    // MARK: - VideoPresentationInfo Struct

    func test_identityTransform_orientedSizeEqualsRaw() {
        let info = VideoPresentationInfo(
            rawTrackSize: CGSize(width: 1920, height: 1080),
            preferredTransform: .identity
        )

        XCTAssertEqual(info.orientedSize.width, 1920, accuracy: 0.01)
        XCTAssertEqual(info.orientedSize.height, 1080, accuracy: 0.01)
        assertMatrixEqual(info.uvTransform, matrix_identity_float4x4)
    }

    func test_90CW_orientedSizeSwapped() {
        // Standard Apple 90° CW portrait: tx=1080, a=0, b=1, c=-1, d=0
        let transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        let info = VideoPresentationInfo(
            rawTrackSize: CGSize(width: 1920, height: 1080),
            preferredTransform: transform
        )

        XCTAssertEqual(info.orientedSize.width, 1080, accuracy: 0.01)
        XCTAssertEqual(info.orientedSize.height, 1920, accuracy: 0.01)

        // UV transform maps oriented quad UV → raw texture UV: (u,v) → (v, 1-u)
        let uv = info.uvTransform
        // Column 0: (a'=0, b'=-1, 0, 0)
        XCTAssertEqual(uv.columns.0.x, 0, accuracy: 0.001)
        XCTAssertEqual(uv.columns.0.y, -1, accuracy: 0.001)
        // Column 1: (c'=1, d'=0, 0, 0)
        XCTAssertEqual(uv.columns.1.x, 1, accuracy: 0.001)
        XCTAssertEqual(uv.columns.1.y, 0, accuracy: 0.001)
        // Column 3: (tx'=0, ty'=1, 0, 1)
        XCTAssertEqual(uv.columns.3.x, 0, accuracy: 0.001)
        XCTAssertEqual(uv.columns.3.y, 1, accuracy: 0.001)
    }

    func test_180_orientedSizeSameAsRaw() {
        // 180°: a=-1, d=-1, tx=1920, ty=1080
        let transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1920, ty: 1080)
        let info = VideoPresentationInfo(
            rawTrackSize: CGSize(width: 1920, height: 1080),
            preferredTransform: transform
        )

        XCTAssertEqual(info.orientedSize.width, 1920, accuracy: 0.01)
        XCTAssertEqual(info.orientedSize.height, 1080, accuracy: 0.01)

        let uv = info.uvTransform
        // a=-1, d=-1
        XCTAssertEqual(uv.columns.0.x, -1, accuracy: 0.001)
        XCTAssertEqual(uv.columns.1.y, -1, accuracy: 0.001)
        // tx/w=1, ty/h=1
        XCTAssertEqual(uv.columns.3.x, 1.0, accuracy: 0.001)
        XCTAssertEqual(uv.columns.3.y, 1.0, accuracy: 0.001)
    }

    func test_90CCW_orientedSizeSwapped() {
        // 90° CCW: a=0, b=-1, c=1, d=0, tx=0, ty=1920
        let transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1920)
        let info = VideoPresentationInfo(
            rawTrackSize: CGSize(width: 1920, height: 1080),
            preferredTransform: transform
        )

        XCTAssertEqual(info.orientedSize.width, 1080, accuracy: 0.01)
        XCTAssertEqual(info.orientedSize.height, 1920, accuracy: 0.01)

        // UV transform maps oriented quad UV → raw texture UV: (u,v) → (1-v, u)
        let uv = info.uvTransform
        // Column 0: (a'=0, b'=1, 0, 0)
        XCTAssertEqual(uv.columns.0.x, 0, accuracy: 0.001)
        XCTAssertEqual(uv.columns.0.y, 1, accuracy: 0.001)
        // Column 1: (c'=-1, d'=0, 0, 0)
        XCTAssertEqual(uv.columns.1.x, -1, accuracy: 0.001)
        XCTAssertEqual(uv.columns.1.y, 0, accuracy: 0.001)
        // Column 3: (tx'=1, ty'=0, 0, 1)
        XCTAssertEqual(uv.columns.3.x, 1, accuracy: 0.001)
        XCTAssertEqual(uv.columns.3.y, 0, accuracy: 0.001)
    }

    func test_equatable() {
        let a = VideoPresentationInfo(
            rawTrackSize: CGSize(width: 1920, height: 1080),
            preferredTransform: .identity
        )
        let b = VideoPresentationInfo(
            rawTrackSize: CGSize(width: 1920, height: 1080),
            preferredTransform: .identity
        )
        let c = VideoPresentationInfo(
            rawTrackSize: CGSize(width: 1080, height: 1920),
            preferredTransform: .identity
        )
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - Provider Metadata Lifecycle

    func test_inMemoryTextureProvider_metadata() {
        guard MTLCreateSystemDefaultDevice() != nil else {
            XCTSkip("Metal not available")
            return
        }

        let provider = InMemoryTextureProvider()
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

    func test_threadSafeInMemoryTextureProvider_metadata() {
        guard MTLCreateSystemDefaultDevice() != nil else {
            XCTSkip("Metal not available")
            return
        }

        let provider = ThreadSafeInMemoryTextureProvider()
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

    func test_scenePackageTextureProvider_metadata() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTSkip("Metal not available")
            return
        }

        let assetIndex = AssetIndexIR()
        let resolver = CompositeAssetResolver(localIndex: .empty, sharedIndex: .empty)
        let provider = ScenePackageTextureProvider(
            device: device,
            assetIndex: assetIndex,
            resolver: resolver
        )

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

    func test_layeredTextureProvider_metadata_ownOverridesOverlay() {
        guard MTLCreateSystemDefaultDevice() != nil else {
            XCTSkip("Metal not available")
            return
        }

        let base = InMemoryTextureProvider()
        let overlay = InMemoryTextureProvider()
        let layered = LayeredTextureProvider(base: base, overlay: overlay)

        let infoA = VideoPresentationInfo(
            rawTrackSize: CGSize(width: 1920, height: 1080),
            preferredTransform: .identity
        )
        let infoB = VideoPresentationInfo(
            rawTrackSize: CGSize(width: 1080, height: 1920),
            preferredTransform: .identity
        )

        // Set on overlay — layered should see it
        overlay.setPresentationInfo(infoA, for: "asset_1")
        XCTAssertEqual(layered.presentationInfo(for: "asset_1"), infoA)

        // Set on layered itself — should override overlay
        layered.setPresentationInfo(infoB, for: "asset_1")
        XCTAssertEqual(layered.presentationInfo(for: "asset_1"), infoB)

        // Remove from layered — should fall through to overlay
        layered.removePresentationInfo(for: "asset_1")
        XCTAssertEqual(layered.presentationInfo(for: "asset_1"), infoA)

        // Set on base — layered should see it after overlay is cleared
        base.setPresentationInfo(infoB, for: "asset_2")
        XCTAssertEqual(layered.presentationInfo(for: "asset_2"), infoB)
    }

    func test_scenePackageBaseTextureProvider_doesNotConformToMetadataProvider() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTSkip("Metal not available")
            return
        }

        let assetIndex = AssetIndexIR()
        let resolver = CompositeAssetResolver(localIndex: .empty, sharedIndex: .empty)
        let provider = ScenePackageBaseTextureProvider(
            device: device,
            assetIndex: assetIndex,
            resolver: resolver
        )

        // ScenePackageBaseTextureProvider should NOT conform
        XCTAssertNil(provider as? AssetPresentationInfoProvider)
    }

    // MARK: - Uniform Stride

    func test_videoQuadUniforms_stride_is160() {
        XCTAssertEqual(MemoryLayout<VideoQuadUniforms>.stride, 160,
                       "VideoQuadUniforms stride must be 160 bytes to match Metal shader")
    }

    func test_quadUniforms_stride_unchanged_at96() {
        XCTAssertEqual(MemoryLayout<QuadUniforms>.stride, 96,
                       "QuadUniforms stride must remain 96 bytes")
    }

    // MARK: - Helpers

    private func assertMatrixEqual(
        _ a: simd_float4x4,
        _ b: simd_float4x4,
        accuracy: Float = 0.001,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for col in 0..<4 {
            for row in 0..<4 {
                XCTAssertEqual(a[col][row], b[col][row], accuracy: accuracy,
                               "Matrix mismatch at [\(col)][\(row)]", file: file, line: line)
            }
        }
    }
}
