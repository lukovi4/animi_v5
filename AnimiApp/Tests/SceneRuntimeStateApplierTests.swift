import XCTest
@testable import AnimiApp
import TVECore

// MARK: - ScenePlayer Spy

@MainActor
private final class ScenePlayerSpy: ScenePlayerApplying {
    enum Call: Equatable {
        case restore
        case applyVariantSelection([String: String])
        case setUserTransform(blockId: String, transform: Matrix2D)
        case setUserMediaPresent(blockId: String, present: Bool)
        case setLayerToggle(blockId: String, toggleId: String, enabled: Bool)
    }

    var calls: [Call] = []
    var mediaInputsByBlockId: [String: MediaInput] = [:]

    func mediaInput(blockId: String) -> MediaInput? { mediaInputsByBlockId[blockId] }
    func applyVariantSelection(_ mapping: [String: String]) { calls.append(.applyVariantSelection(mapping)) }
    func setUserTransform(blockId: String, transform: Matrix2D) { calls.append(.setUserTransform(blockId: blockId, transform: transform)) }
    func setUserMediaPresent(blockId: String, present: Bool) { calls.append(.setUserMediaPresent(blockId: blockId, present: present)) }
    func setLayerToggle(blockId: String, toggleId: String, enabled: Bool) { calls.append(.setLayerToggle(blockId: blockId, toggleId: toggleId, enabled: enabled)) }
}

/// Tests for SceneRuntimeStateApplier: canonical apply order, resolver integration, fast-paths.
final class SceneRuntimeStateApplierTests: XCTestCase {

    // MARK: - Apply Order (Spy-Based)

    @MainActor
    func test_applyOrder_restoreBeforeVariantsBeforePlacementBeforeToggles() {
        var state = SceneState.empty
        state.variantOverrides = ["block1": "variant_a"]
        state.userTransforms = ["block1": Matrix2D.translation(x: 10, y: 20)]
        state.layerToggles = ["block1": ["toggle1": true]]
        state.mediaSlotsByBlockId = [
            "block1": .photo(
                mediaRef: .file("Media/UserMedia/test.jpg", mediaKind: .photo),
                placement: .default(fitMode: .cover)
            )
        ]

        let spy = ScenePlayerSpy()
        SceneRuntimeStateApplier.apply(
            state,
            player: spy,
            userMediaService: nil,
            restore: { _, _ in
                spy.calls.append(.restore)
                return 1
            }
        )

        // Canonical order: restore → variants → placement → toggles
        XCTAssertEqual(spy.calls.count, 4)
        XCTAssertEqual(spy.calls[0], .restore)
        XCTAssertEqual(spy.calls[1], .applyVariantSelection(["block1": "variant_a"]))
        // spy has no mediaInput for block1 → resolveTransform returns .identity
        XCTAssertEqual(spy.calls[2], .setUserTransform(blockId: "block1", transform: .identity))
        XCTAssertEqual(spy.calls[3], .setLayerToggle(blockId: "block1", toggleId: "toggle1", enabled: true))
    }

    // MARK: - Slot Change

    @MainActor
    func test_applySlotChange_insert_restoresBeforePlacement() {
        let spy = ScenePlayerSpy()
        let slot = SceneMediaSlot.photo(
            mediaRef: .file("Media/photo.jpg", mediaKind: .photo),
            placement: .default(fitMode: .cover)
        )

        SceneRuntimeStateApplier.applySlotChange(
            blockId: "block1",
            slot: slot,
            player: spy,
            restore: { _, _ in
                spy.calls.append(.restore)
                return 1
            }
        )

        // restore must come before placement setUserTransform
        XCTAssertGreaterThanOrEqual(spy.calls.count, 2)
        XCTAssertEqual(spy.calls[0], .restore)
        // spy has no mediaInput → resolveTransform returns .identity
        XCTAssertEqual(spy.calls[1], .setUserTransform(blockId: "block1", transform: .identity))
    }

    @MainActor
    func test_applySlotChange_remove_hidesMedia() {
        let spy = ScenePlayerSpy()

        SceneRuntimeStateApplier.applySlotChange(
            blockId: "block1",
            slot: nil,
            player: spy
        )

        XCTAssertEqual(spy.calls, [.setUserMediaPresent(blockId: "block1", present: false)])
    }

    // MARK: - Placement vs Legacy Transform

    @MainActor
    func test_placementOverridesLegacyUserTransform() {
        let legacyMatrix = Matrix2D.translation(x: 999, y: 999)
        var state = SceneState.empty
        state.userTransforms = ["block1": legacyMatrix]
        state.mediaSlotsByBlockId = [
            "block1": .photo(
                mediaRef: .file("Media/photo.jpg", mediaKind: .photo),
                placement: .default(fitMode: .cover)
            )
        ]

        let spy = ScenePlayerSpy()
        // spy has no mediaInput → resolver returns .identity (not the legacy 999,999 translation)
        SceneRuntimeStateApplier.apply(state, player: spy, userMediaService: nil)

        let transformCalls = spy.calls.compactMap { call -> Matrix2D? in
            if case .setUserTransform(blockId: "block1", transform: let t) = call { return t }
            return nil
        }
        XCTAssertEqual(transformCalls.count, 1, "Placement should override legacy — exactly one setUserTransform")
        XCTAssertEqual(transformCalls[0], .identity, "Should use resolver path (.identity since no mediaInput), not legacy translation")
        XCTAssertNotEqual(transformCalls[0], legacyMatrix, "Must NOT use the legacy userTransform")
    }

    @MainActor
    func test_legacyFallback_usesUserTransform() {
        var state = SceneState.empty
        let legacyTransform = Matrix2D.translation(x: 42, y: 7)
        state.userTransforms = ["blockLegacy": legacyTransform]
        state.mediaSlotsByBlockId = [
            "blockLegacy": .photo(
                mediaRef: .file("Media/photo.jpg", mediaKind: .photo)
                // placement is nil — legacy path
            )
        ]

        let spy = ScenePlayerSpy()
        SceneRuntimeStateApplier.apply(state, player: spy, userMediaService: nil)

        // Legacy block should get setUserTransform with the exact legacy matrix
        let transformCalls = spy.calls.compactMap { call -> Matrix2D? in
            if case .setUserTransform(blockId: "blockLegacy", transform: let t) = call { return t }
            return nil
        }
        XCTAssertEqual(transformCalls.count, 1, "Legacy block should receive setUserTransform from userTransforms")
        XCTAssertEqual(transformCalls[0], legacyTransform, "Legacy path must pass through the exact userTransform matrix")
    }

    // MARK: - Fast-Path: Placement Change

    @MainActor
    func test_applyPlacementChange_callsSetUserTransform_once() {
        let spy = ScenePlayerSpy()
        let placement = MediaPlacementState.default(fitMode: .cover)

        SceneRuntimeStateApplier.applyPlacementChange(
            blockId: "block1",
            placement: placement,
            player: spy
        )

        let transformCalls = spy.calls.compactMap { call -> Matrix2D? in
            if case .setUserTransform(blockId: _, transform: let t) = call { return t }
            return nil
        }
        XCTAssertEqual(transformCalls.count, 1, "Fast-path should call setUserTransform exactly once")
        // spy has no mediaInput → resolveTransform returns .identity
        XCTAssertEqual(transformCalls[0], .identity)
    }

    // MARK: - Fast-Path: Visibility Change

    @MainActor
    func test_applyVisibilityChange_callsSetUserMediaPresent() {
        let spy = ScenePlayerSpy()

        SceneRuntimeStateApplier.applyVisibilityChange(
            blockId: "block1",
            visible: true,
            playerApplying: spy
        )

        XCTAssertEqual(spy.calls, [.setUserMediaPresent(blockId: "block1", present: true)])
    }

    // MARK: - Resolver Integration: resolveTransformsForExport parity

    func test_resolveTransformsForExport_placementProducesMatrix() {
        let placement = MediaPlacementState(fitMode: .cover, offsetX: 10, offsetY: -5, userScale: 1.5)
        let slotRect = Rect(x: 0, y: 0, width: 540, height: 960)
        let geometry = MediaPlacementResolver.SlotGeometry(
            slotRect: slotRect,
            mediaWidth: slotRect.width,
            mediaHeight: slotRect.height
        )

        let resolved = MediaPlacementResolver.resolve(placement: placement, geometry: geometry)

        XCTAssertFalse(resolved.isApproximatelyEqual(to: .identity, epsilon: 1e-3))
        XCTAssertNotNil(resolved.inverse, "Resolved matrix must be invertible")
    }

    func test_resolveTransformsForExport_defaultPlacementIsBaseFit() {
        let placement = MediaPlacementState.default(fitMode: .cover)
        let slotRect = Rect(x: 0, y: 0, width: 540, height: 960)
        let geometry = MediaPlacementResolver.SlotGeometry(
            slotRect: slotRect,
            mediaWidth: slotRect.width,
            mediaHeight: slotRect.height
        )

        let resolved = MediaPlacementResolver.resolve(placement: placement, geometry: geometry)
        let baseFit = MediaPlacementResolver.baseFitTransform(fitMode: .cover, geometry: geometry)

        XCTAssertTrue(
            resolved.isApproximatelyEqual(to: baseFit, epsilon: 1e-10),
            "Default placement with slot-as-media-size should equal baseFit"
        )
    }

    // MARK: - Preview / Export Parity

    func test_previewAndExport_useSameResolverPath() {
        let placement = MediaPlacementState(fitMode: .contain, offsetX: 20, offsetY: 10, userScale: 2.0, rotationDegrees: 45)
        let slotRect = Rect(x: 50, y: 30, width: 400, height: 300)

        let previewGeometry = MediaPlacementResolver.SlotGeometry(
            slotRect: slotRect,
            mediaWidth: slotRect.width,
            mediaHeight: slotRect.height
        )
        let previewMatrix = MediaPlacementResolver.resolve(placement: placement, geometry: previewGeometry)

        let exportGeometry = MediaPlacementResolver.SlotGeometry(
            slotRect: slotRect,
            mediaWidth: slotRect.width,
            mediaHeight: slotRect.height
        )
        let exportMatrix = MediaPlacementResolver.resolve(placement: placement, geometry: exportGeometry)

        XCTAssertTrue(
            previewMatrix.isApproximatelyEqual(to: exportMatrix, epsilon: 1e-10),
            "Preview and export must produce identical transforms for same input"
        )
    }

    // MARK: - Fast-Path: Placement Resolver

    func test_fastPath_placementChange_producesValidMatrix() {
        let placement = MediaPlacementState(fitMode: .cover, offsetX: 15, offsetY: -8, userScale: 1.2, rotationDegrees: 30)
        let slotRect = Rect(x: 0, y: 0, width: 540, height: 960)
        let geometry = MediaPlacementResolver.SlotGeometry(
            slotRect: slotRect,
            mediaWidth: slotRect.width,
            mediaHeight: slotRect.height
        )
        let matrix = MediaPlacementResolver.resolve(placement: placement, geometry: geometry)

        XCTAssertNotNil(matrix.inverse, "Fast-path matrix must be invertible")
        XCTAssertFalse(matrix.isApproximatelyEqual(to: .identity, epsilon: 1e-3))
    }

    // MARK: - Slot-As-Media-Size Proxy

    func test_slotAsMediaProxy_coverProducesIdentityScale() {
        let slotRect = Rect(x: 100, y: 50, width: 400, height: 300)
        let geometry = MediaPlacementResolver.SlotGeometry(
            slotRect: slotRect,
            mediaWidth: 400,
            mediaHeight: 300
        )
        let baseFit = MediaPlacementResolver.baseFitTransform(fitMode: .cover, geometry: geometry)

        XCTAssertEqual(baseFit.a, 1.0, accuracy: 1e-10)
        XCTAssertEqual(baseFit.d, 1.0, accuracy: 1e-10)
        XCTAssertEqual(baseFit.tx, 100, accuracy: 1e-10)
        XCTAssertEqual(baseFit.ty, 50, accuracy: 1e-10)
    }
}
