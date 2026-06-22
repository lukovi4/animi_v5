import XCTest
import Foundation
import AnimiEngineCore
import AnimiEngineRenderModel
@testable import AnimiEngineRenderGraph

/// CP7.8 — value-level tests for the dynamic texture-backed pixel input. NO GPU. Pins the canonical
/// contract: the dynamic descriptor is value-only (no bytes / no content hash), deterministic +
/// identity-by-source-id in canonical encoding, and the existing bytes path stays byte-identical (the
/// ReferenceData oracle is unaffected — the dynamicTextureInputs key is omitted when empty).
final class CP78DynamicTextureValueTests: XCTestCase {

    private func dynDescriptor(
        id: String = "video:scene/block:1000", w: Int64 = 1080, h: Int64 = 1920,
        turns: Int = 1, orientation: PixelOrientation = .up
    ) throws -> RenderResourceDescriptor {
        try RenderResourceDescriptor(
            dynamicTextureSourceID: id, width: w, height: h, pixelFormat: .bgra8,
            orientation: orientation, orientationQuarterTurns: turns, colorContract: .task003)
    }

    private func canonicalBytes(_ d: RenderResourceDescriptor) throws -> [UInt8] {
        let cmd = try RenderCommand(ordinal: 0, payload: .declareResource(d))
        return Array(try RenderCanonicalEncoding.canonicalBytes(cmd.canonicalValue()))
    }

    // MARK: - Value-only contract (no bytes, no hash, no GPU handle)

    func test_dynamicDescriptor_carriesNoBytesAndNoHash() throws {
        let d = try dynDescriptor()
        XCTAssertEqual(d.kind, .dynamicTexturePixelInput)
        XCTAssertNil(d.pixels)
        XCTAssertEqual(d.pixelContentHash, "")
        XCTAssertEqual(d.dynamicTextureSourceID, "video:scene/block:1000")
        XCTAssertEqual(d.dynamicOrientationQuarterTurns, 1)
        XCTAssertNil(d.surfaceProfile)
        XCTAssertNil(d.surfaceStorage)
    }

    func test_dynamicDescriptor_rejectsBadDimsAndQuarterTurns() {
        XCTAssertThrowsError(try dynDescriptor(w: 0))
        XCTAssertThrowsError(try dynDescriptor(h: -10))
        XCTAssertThrowsError(try dynDescriptor(turns: 4))
        XCTAssertThrowsError(try dynDescriptor(turns: -1))
    }

    // MARK: - Canonical determinism

    func test_canonicalValue_isDeterministic_andIdentityBySourceID() throws {
        let a1 = try canonicalBytes(try dynDescriptor(id: "video:s/b:1000", turns: 1))
        let a2 = try canonicalBytes(try dynDescriptor(id: "video:s/b:1000", turns: 1))
        let b  = try canonicalBytes(try dynDescriptor(id: "video:s/b:2000", turns: 1))
        let c  = try canonicalBytes(try dynDescriptor(id: "video:s/b:1000", turns: 2))
        XCTAssertEqual(a1, a2, "same source id + dims + orientation must encode identically")
        XCTAssertNotEqual(a1, b, "different PTS source id must change identity")
        XCTAssertNotEqual(a1, c, "different quarter-turn must change identity")
    }

    func test_dynamicDescriptor_hashableEqualityMatchesValue() throws {
        XCTAssertEqual(try dynDescriptor(), try dynDescriptor())
        XCTAssertNotEqual(try dynDescriptor(turns: 0), try dynDescriptor(turns: 2))
    }

    // MARK: - ResolvedDynamicTextureInput value type

    func test_resolvedDynamicTextureInput_validatesDimsAndTurns() throws {
        let ok = try ResolvedDynamicTextureInput(
            id: try PixelInputID("video:x:1"), width: 100, height: 200,
            bytesFormat: .bgra8, orientation: .up, orientationQuarterTurns: 3)
        XCTAssertEqual(ok.width, 100); XCTAssertEqual(ok.height, 200); XCTAssertEqual(ok.orientationQuarterTurns, 3)
        XCTAssertThrowsError(try ResolvedDynamicTextureInput(
            id: try PixelInputID("v"), width: 0, height: 10, bytesFormat: .bgra8, orientation: .up, orientationQuarterTurns: 0))
        XCTAssertThrowsError(try ResolvedDynamicTextureInput(
            id: try PixelInputID("v"), width: 10, height: 10, bytesFormat: .bgra8, orientation: .up, orientationQuarterTurns: 5))
    }

    // MARK: - ResolvedFrameInput dynamic threading + bytes-path invariance

    func test_resolvedFrameInput_emptyDynamic_omitsKeyFromCanonical() throws {
        // A photo-only frame must not carry a dynamicTextureInputs canonical key (byte-identical to pre-CP7.8).
        let entry = try ResolvedSceneLayerEntry(
            key: .sceneLayer(sceneID: try SceneInstanceID("s"), role: .sole, layerID: try LayerID("l")),
            program: try GraphTestFixtures.program(block: "b"),
            pixelInput: try GraphTestFixtures.pixels("photo-1"),
            placement: ResolvedMediaPlacement(fitMode: .contain, transform: .identity, clip: .none))
        let frame = try ResolvedFrameInput(sceneLayers: [entry], overlays: [])
        XCTAssertEqual(frame.dynamicTextureCount, 0)
        let json = String(decoding: try RenderCanonicalEncoding.canonicalBytes(frame.canonicalValue()), as: UTF8.self)
        XCTAssertFalse(json.contains("dynamicTextureInputs"), "empty dynamic set must be omitted from canonical bytes")
    }

    func test_resolvedFrameInput_carriesDynamicEntry() throws {
        let dyn = try ResolvedDynamicTextureInput(
            id: try PixelInputID("video:v:1"), width: 64, height: 64, bytesFormat: .bgra8,
            orientation: .up, orientationQuarterTurns: 1)
        let entry = try ResolvedSceneLayerEntry(
            key: .sceneLayer(sceneID: try SceneInstanceID("s"), role: .sole, layerID: try LayerID("l")),
            program: try GraphTestFixtures.program(block: "b"),
            source: .dynamicTexture(dyn),
            placement: ResolvedMediaPlacement(fitMode: .contain, transform: .identity, clip: .none))
        let frame = try ResolvedFrameInput(sceneLayers: [entry], overlays: [])
        XCTAssertEqual(frame.dynamicTextureCount, 1)
        XCTAssertNotNil(frame.dynamicTexture(try PixelInputID("video:v:1")))
        XCTAssertNil(frame.pixelInput(try PixelInputID("video:v:1")), "dynamic id must NOT be a bytes pixel input")
        let json = String(decoding: try RenderCanonicalEncoding.canonicalBytes(frame.canonicalValue()), as: UTF8.self)
        XCTAssertTrue(json.contains("dynamicTextureInputs"))
    }

    func test_resolvedFrameInput_dynamicAndBytes_neverShareID() throws {
        let id = "dup-id"
        let bytesEntry = try ResolvedSceneLayerEntry(
            key: .sceneLayer(sceneID: try SceneInstanceID("s1"), role: .sole, layerID: try LayerID("l1")),
            program: try GraphTestFixtures.program(block: "b1"),
            pixelInput: try GraphTestFixtures.pixels(id),
            placement: ResolvedMediaPlacement(fitMode: .contain, transform: .identity, clip: .none))
        let dynEntry = try ResolvedSceneLayerEntry(
            key: .sceneLayer(sceneID: try SceneInstanceID("s2"), role: .sole, layerID: try LayerID("l2")),
            program: try GraphTestFixtures.program(block: "b2"),
            source: .dynamicTexture(try ResolvedDynamicTextureInput(
                id: try PixelInputID(id), width: 10, height: 10, bytesFormat: .bgra8,
                orientation: .up, orientationQuarterTurns: 0)),
            placement: ResolvedMediaPlacement(fitMode: .contain, transform: .identity, clip: .none))
        XCTAssertThrowsError(try ResolvedFrameInput(sceneLayers: [bytesEntry, dynEntry], overlays: []))
    }
}
