import XCTest
import Metal
@testable import TVECore

final class MaskExtractionTests: XCTestCase {

    // MARK: - extractMaskGroupScope Tests

    func testExtract_singleMask_returnsCorrectScope() throws {
        let commands: [RenderCommand] = [
            .beginMask(mode: .add, inverted: false, pathId: PathID(1), opacity: 1.0, frame: 0),
            .pushTransform(.identity),
            .popTransform,
            .endMask
        ]

        let renderer = try makeTestRenderer()
        guard let scope = renderer.extractMaskGroupScope(from: commands, startIndex: 0) else {
            XCTFail("Should extract scope")
            return
        }

        XCTAssertEqual(scope.opsInAeOrder.count, 1)
        XCTAssertEqual(scope.opsInAeOrder[0].mode, .add)
        XCTAssertEqual(scope.opsInAeOrder[0].inverted, false)
        XCTAssertEqual(scope.opsInAeOrder[0].pathId, PathID(1))
        XCTAssertEqual(scope.opsInAeOrder[0].opacity, 1.0)
        XCTAssertEqual(scope.innerCommands.count, 2) // pushTransform, popTransform
        XCTAssertEqual(scope.endIndex, 4) // Next command after endMask
    }

    func testExtract_threeMasks_returnsAeOrder() throws {
        // Emitted in reverse order (as AnimIR does): M2, M1, M0
        // Should return in AE order: M0, M1, M2
        let commands: [RenderCommand] = [
            .beginMask(mode: .subtract, inverted: false, pathId: PathID(2), opacity: 0.8, frame: 0),
            .beginMask(mode: .intersect, inverted: true, pathId: PathID(1), opacity: 0.5, frame: 0),
            .beginMask(mode: .add, inverted: false, pathId: PathID(0), opacity: 1.0, frame: 0),
            .drawImage(assetId: "test", opacity: 1.0),
            .endMask,
            .endMask,
            .endMask
        ]

        let renderer = try makeTestRenderer()
        guard let scope = renderer.extractMaskGroupScope(from: commands, startIndex: 0) else {
            XCTFail("Should extract scope")
            return
        }

        XCTAssertEqual(scope.opsInAeOrder.count, 3)

        // Verify AE order (reversed from emission)
        XCTAssertEqual(scope.opsInAeOrder[0].pathId, PathID(0))
        XCTAssertEqual(scope.opsInAeOrder[0].mode, .add)
        XCTAssertEqual(scope.opsInAeOrder[0].inverted, false)
        XCTAssertEqual(scope.opsInAeOrder[0].opacity, 1.0)

        XCTAssertEqual(scope.opsInAeOrder[1].pathId, PathID(1))
        XCTAssertEqual(scope.opsInAeOrder[1].mode, .intersect)
        XCTAssertEqual(scope.opsInAeOrder[1].inverted, true)
        XCTAssertEqual(scope.opsInAeOrder[1].opacity, 0.5)

        XCTAssertEqual(scope.opsInAeOrder[2].pathId, PathID(2))
        XCTAssertEqual(scope.opsInAeOrder[2].mode, .subtract)
        XCTAssertEqual(scope.opsInAeOrder[2].inverted, false)
        XCTAssertEqual(scope.opsInAeOrder[2].opacity, 0.8)

        // Verify innerCommands is exactly [.drawImage]
        XCTAssertEqual(scope.innerCommands.count, 1)
        if case .drawImage(let assetId, _) = scope.innerCommands[0] {
            XCTAssertEqual(assetId, "test")
        } else {
            XCTFail("Inner command should be drawImage")
        }

        XCTAssertEqual(scope.endIndex, 7)
    }

    func testExtract_legacyBeginMaskAdd_convertsToAdd() throws {
        let commands: [RenderCommand] = [
            .beginMaskAdd(pathId: PathID(5), opacity: 0.75, frame: 10),
            .pushTransform(.identity),
            .endMask
        ]

        let renderer = try makeTestRenderer()
        guard let scope = renderer.extractMaskGroupScope(from: commands, startIndex: 0) else {
            XCTFail("Should extract scope")
            return
        }

        XCTAssertEqual(scope.opsInAeOrder.count, 1)
        XCTAssertEqual(scope.opsInAeOrder[0].mode, .add)
        XCTAssertEqual(scope.opsInAeOrder[0].inverted, false)
        XCTAssertEqual(scope.opsInAeOrder[0].pathId, PathID(5))
        XCTAssertEqual(scope.opsInAeOrder[0].opacity, 0.75)
        XCTAssertEqual(scope.opsInAeOrder[0].frame, 10)
    }

    func testExtract_mixedNewAndLegacyMasks_handledCorrectly() throws {
        let commands: [RenderCommand] = [
            .beginMask(mode: .subtract, inverted: true, pathId: PathID(2), opacity: 0.9, frame: 0),
            .beginMaskAdd(pathId: PathID(1), opacity: 0.5, frame: 0),
            .drawImage(assetId: "inner", opacity: 1.0),
            .endMask,
            .endMask
        ]

        let renderer = try makeTestRenderer()
        guard let scope = renderer.extractMaskGroupScope(from: commands, startIndex: 0) else {
            XCTFail("Should extract scope")
            return
        }

        XCTAssertEqual(scope.opsInAeOrder.count, 2)

        // First in AE order (was second in emission)
        XCTAssertEqual(scope.opsInAeOrder[0].pathId, PathID(1))
        XCTAssertEqual(scope.opsInAeOrder[0].mode, .add)
        XCTAssertEqual(scope.opsInAeOrder[0].inverted, false)

        // Second in AE order (was first in emission)
        XCTAssertEqual(scope.opsInAeOrder[1].pathId, PathID(2))
        XCTAssertEqual(scope.opsInAeOrder[1].mode, .subtract)
        XCTAssertEqual(scope.opsInAeOrder[1].inverted, true)
    }

    func testExtract_emptyInnerCommands_succeeds() throws {
        let commands: [RenderCommand] = [
            .beginMask(mode: .add, inverted: false, pathId: PathID(1), opacity: 1.0, frame: 0),
            .endMask
        ]

        let renderer = try makeTestRenderer()
        guard let scope = renderer.extractMaskGroupScope(from: commands, startIndex: 0) else {
            XCTFail("Should extract scope")
            return
        }

        XCTAssertEqual(scope.opsInAeOrder.count, 1)
        XCTAssertTrue(scope.innerCommands.isEmpty)
        XCTAssertEqual(scope.endIndex, 2)
    }

    func testExtract_invalidStartIndex_returnsNil() throws {
        let commands: [RenderCommand] = [
            .pushTransform(.identity)
        ]

        let renderer = try makeTestRenderer()
        let scope = renderer.extractMaskGroupScope(from: commands, startIndex: 0)
        XCTAssertNil(scope, "Should return nil for non-mask start command")
    }

    func testExtract_outOfBoundsStartIndex_returnsNil() throws {
        let commands: [RenderCommand] = [
            .beginMask(mode: .add, inverted: false, pathId: PathID(1), opacity: 1.0, frame: 0),
            .endMask
        ]

        let renderer = try makeTestRenderer()
        let scope = renderer.extractMaskGroupScope(from: commands, startIndex: 10)
        XCTAssertNil(scope, "Should return nil for out of bounds index")
    }

    func testExtract_unmatchedEndMask_returnsNil() throws {
        let commands: [RenderCommand] = [
            .beginMask(mode: .add, inverted: false, pathId: PathID(1), opacity: 1.0, frame: 0),
            .pushTransform(.identity)
            // Missing endMask
        ]

        let renderer = try makeTestRenderer()
        let scope = renderer.extractMaskGroupScope(from: commands, startIndex: 0)
        XCTAssertNil(scope, "Should return nil for unmatched endMask")
    }

    func testExtract_innerCommandsCorrectRange() throws {
        // Verify that innerCommands doesn't include any beginMask or endMask
        let commands: [RenderCommand] = [
            .beginMask(mode: .add, inverted: false, pathId: PathID(0), opacity: 1.0, frame: 0),
            .pushTransform(.identity),
            .drawImage(assetId: "img1", opacity: 1.0),
            .drawImage(assetId: "img2", opacity: 0.5),
            .popTransform,
            .endMask
        ]

        let renderer = try makeTestRenderer()
        guard let scope = renderer.extractMaskGroupScope(from: commands, startIndex: 0) else {
            XCTFail("Should extract scope")
            return
        }

        XCTAssertEqual(scope.innerCommands.count, 4)

        // Verify none of the inner commands are mask commands
        for cmd in scope.innerCommands {
            switch cmd {
            case .beginMask, .beginMaskAdd, .endMask:
                XCTFail("Inner commands should not contain mask commands")
            default:
                break
            }
        }
    }

    func testExtract_nestedBeginMaskInsideInner_returnsNil() throws {
        // Nested beginMask inside inner content is unsupported and should return nil
        let commands: [RenderCommand] = [
            .beginMask(mode: .add, inverted: false, pathId: PathID(1), opacity: 1.0, frame: 0),
            .pushTransform(.identity),
            .beginMask(mode: .subtract, inverted: false, pathId: PathID(2), opacity: 1.0, frame: 0), // Nested!
            .drawImage(assetId: "test", opacity: 1.0),
            .endMask,
            .popTransform,
            .endMask
        ]

        let renderer = try makeTestRenderer()
        let scope = renderer.extractMaskGroupScope(from: commands, startIndex: 0)
        XCTAssertNil(scope, "Should return nil when nested beginMask found inside inner content")
    }

    // MARK: - initialAccumulatorValue Tests

    func testInitialValue_addFirst_returnsZero() {
        let ops = [
            MaskOp(mode: .add, inverted: false, pathId: PathID(1), opacity: 1.0, frame: 0)
        ]
        XCTAssertEqual(initialAccumulatorValue(for: ops), 0.0)
    }

    func testInitialValue_subtractFirst_returnsOne() {
        let ops = [
            MaskOp(mode: .subtract, inverted: false, pathId: PathID(1), opacity: 1.0, frame: 0)
        ]
        XCTAssertEqual(initialAccumulatorValue(for: ops), 1.0)
    }

    func testInitialValue_intersectFirst_returnsOne() {
        let ops = [
            MaskOp(mode: .intersect, inverted: false, pathId: PathID(1), opacity: 1.0, frame: 0)
        ]
        XCTAssertEqual(initialAccumulatorValue(for: ops), 1.0)
    }

    func testInitialValue_emptyOps_returnsZero() {
        let ops: [MaskOp] = []
        XCTAssertEqual(initialAccumulatorValue(for: ops), 0.0)
    }

    func testInitialValue_multipleOps_usesFirst() {
        // First is subtract, so should return 1.0 regardless of subsequent ops
        let ops = [
            MaskOp(mode: .subtract, inverted: false, pathId: PathID(1), opacity: 1.0, frame: 0),
            MaskOp(mode: .add, inverted: false, pathId: PathID(2), opacity: 1.0, frame: 0),
            MaskOp(mode: .intersect, inverted: false, pathId: PathID(3), opacity: 1.0, frame: 0)
        ]
        XCTAssertEqual(initialAccumulatorValue(for: ops), 1.0)
    }

    // MARK: - roundClampIntersectBBoxToPixels Tests

    func testBboxRounding_floorsMinsCeilsMaxs() {
        let bbox = CGRect(x: 10.3, y: 20.7, width: 100.2, height: 50.8)
        let result = roundClampIntersectBBoxToPixels(
            bbox,
            targetSize: (width: 500, height: 500),
            scissor: nil,
            expandAA: 0
        )

        guard let result = result else {
            XCTFail("Should return bbox")
            return
        }

        XCTAssertEqual(result.x, 10)       // floor(10.3)
        XCTAssertEqual(result.y, 20)       // floor(20.7)
        // maxX = ceil(10.3 + 100.2) = ceil(110.5) = 111, width = 111 - 10 = 101
        XCTAssertEqual(result.width, 101)
        // maxY = ceil(20.7 + 50.8) = ceil(71.5) = 72, height = 72 - 20 = 52
        XCTAssertEqual(result.height, 52)
    }

    func testBboxRounding_expandsForAA() {
        let bbox = CGRect(x: 10, y: 20, width: 100, height: 50)
        let result = roundClampIntersectBBoxToPixels(
            bbox,
            targetSize: (width: 500, height: 500),
            scissor: nil,
            expandAA: 2
        )

        guard let result = result else {
            XCTFail("Should return bbox")
            return
        }

        XCTAssertEqual(result.x, 8)        // 10 - 2
        XCTAssertEqual(result.y, 18)       // 20 - 2
        XCTAssertEqual(result.width, 104)  // (110 + 2) - 8 = 104
        XCTAssertEqual(result.height, 54)  // (70 + 2) - 18 = 54
    }

    func testBboxRounding_clampsToTarget() {
        let bbox = CGRect(x: -10, y: -5, width: 200, height: 150)
        let result = roundClampIntersectBBoxToPixels(
            bbox,
            targetSize: (width: 100, height: 80),
            scissor: nil,
            expandAA: 0
        )

        guard let result = result else {
            XCTFail("Should return bbox")
            return
        }

        XCTAssertEqual(result.x, 0)
        XCTAssertEqual(result.y, 0)
        XCTAssertEqual(result.width, 100)
        XCTAssertEqual(result.height, 80)
    }

    func testBboxRounding_intersectsWithScissor() {
        let bbox = CGRect(x: 10, y: 20, width: 100, height: 100)
        let scissor = MTLScissorRect(x: 50, y: 50, width: 200, height: 200)

        let result = roundClampIntersectBBoxToPixels(
            bbox,
            targetSize: (width: 500, height: 500),
            scissor: scissor,
            expandAA: 0
        )

        guard let result = result else {
            XCTFail("Should return bbox")
            return
        }

        // Intersection of (10,20,100,100) and (50,50,200,200)
        XCTAssertEqual(result.x, 50)       // max(10, 50)
        XCTAssertEqual(result.y, 50)       // max(20, 50)
        XCTAssertEqual(result.width, 60)   // min(110, 250) - 50 = 60
        XCTAssertEqual(result.height, 70)  // min(120, 250) - 50 = 70
    }

    func testBboxRounding_fullyClipped_returnsNil() {
        let bbox = CGRect(x: 10, y: 20, width: 30, height: 20)
        let scissor = MTLScissorRect(x: 100, y: 100, width: 50, height: 50)

        let result = roundClampIntersectBBoxToPixels(
            bbox,
            targetSize: (width: 500, height: 500),
            scissor: scissor,
            expandAA: 0
        )

        XCTAssertNil(result, "Should return nil when bbox doesn't intersect scissor")
    }

    func testBboxRounding_degenerateBbox_returnsNil() {
        let bbox = CGRect(x: 100, y: 100, width: 0, height: 50)

        let result = roundClampIntersectBBoxToPixels(
            bbox,
            targetSize: (width: 500, height: 500),
            scissor: nil,
            expandAA: 0
        )

        XCTAssertNil(result, "Should return nil for zero-width bbox")
    }

    // MARK: - sampleTriangulatedPositions Tests

    func testSamplePositions_staticPath_returnsPositions() {
        let positions: [Float] = [0, 0, 100, 0, 100, 100, 0, 100]
        let resource = PathResource(
            pathId: PathID(0),
            keyframePositions: [positions],
            keyframeTimes: [0],
            indices: [0, 1, 2, 2, 3, 0],
            vertexCount: 4
        )

        var out: [Float] = []
        resource.sampleTriangulatedPositions(at: 0, into: &out)

        XCTAssertEqual(out, positions)
    }

    func testSamplePositions_animatedPath_interpolates() {
        let pos0: [Float] = [0, 0, 100, 0]
        let pos1: [Float] = [0, 0, 200, 0]
        let resource = PathResource(
            pathId: PathID(0),
            keyframePositions: [pos0, pos1],
            keyframeTimes: [0, 10],
            indices: [0, 1],
            vertexCount: 2,
            keyframeEasing: [.linear]
        )

        var out: [Float] = []
        resource.sampleTriangulatedPositions(at: 5, into: &out)

        // At frame 5, t = 0.5, so x of vertex 1 should be 150
        XCTAssertEqual(out.count, 4)
        XCTAssertEqual(out[0], 0, accuracy: 0.001)   // x0
        XCTAssertEqual(out[1], 0, accuracy: 0.001)   // y0
        XCTAssertEqual(out[2], 150, accuracy: 0.001) // x1 interpolated
        XCTAssertEqual(out[3], 0, accuracy: 0.001)   // y1
    }

    func testSamplePositions_beforeFirstKeyframe_returnsFirst() {
        let pos0: [Float] = [0, 0, 100, 0]
        let pos1: [Float] = [0, 0, 200, 0]
        let resource = PathResource(
            pathId: PathID(0),
            keyframePositions: [pos0, pos1],
            keyframeTimes: [10, 20],
            indices: [0, 1],
            vertexCount: 2
        )

        var out: [Float] = []
        resource.sampleTriangulatedPositions(at: 5, into: &out)

        XCTAssertEqual(out, pos0)
    }

    func testSamplePositions_afterLastKeyframe_returnsLast() {
        let pos0: [Float] = [0, 0, 100, 0]
        let pos1: [Float] = [0, 0, 200, 0]
        let resource = PathResource(
            pathId: PathID(0),
            keyframePositions: [pos0, pos1],
            keyframeTimes: [0, 10],
            indices: [0, 1],
            vertexCount: 2
        )

        var out: [Float] = []
        resource.sampleTriangulatedPositions(at: 100, into: &out)

        XCTAssertEqual(out, pos1)
    }

    func testSamplePositions_reusesOutBuffer() {
        let positions: [Float] = [0, 0, 100, 0, 100, 100]
        let resource = PathResource(
            pathId: PathID(0),
            keyframePositions: [positions],
            keyframeTimes: [0],
            indices: [0, 1, 2],
            vertexCount: 3
        )

        var out: [Float] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10] // Pre-filled with junk
        resource.sampleTriangulatedPositions(at: 0, into: &out)

        // Should clear and fill with actual positions
        XCTAssertEqual(out, positions)
    }

    // MARK: - computeMaskGroupBboxFloat Tests

    func testComputeBbox_skipsIfVertexCountMismatch() {
        // Create a path resource where vertexCount > actual positions stored
        // This simulates a corrupted resource where vertexCount was set incorrectly
        // The scratch guard catches this mismatch
        let positions: [Float] = [0, 0, 100, 0] // Only 2 vertices (4 floats)
        let resource = PathResource(
            pathId: PathID(0),
            keyframePositions: [positions],
            keyframeTimes: [0],
            indices: [0, 1],
            vertexCount: 4 // Claims 4 vertices but only has 2
        )

        var registry = PathRegistry()
        registry.register(resource)

        let op = MaskOp(mode: .add, inverted: false, pathId: PathID(0), opacity: 1.0, frame: 0)

        var scratch: [Float] = []

        let result = computeMaskGroupBboxFloat(
            ops: [op],
            pathRegistry: registry,
            animToViewport: .identity,
            currentTransform: .identity,
            scratch: &scratch
        )

        // Should return nil because scratch has fewer floats than vertexCount*2
        // sampleTriangulatedPositions fills scratch with 4 floats but vertexCount says 4 vertices (need 8)
        XCTAssertNil(result, "Should return nil when scratch has fewer positions than vertexCount requires")
    }

    // MARK: - Helpers

    private func makeTestRenderer() throws -> MetalRenderer {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        return try MetalRenderer(device: device, colorPixelFormat: .bgra8Unorm)
    }
}
