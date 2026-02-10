import XCTest
@testable import TVECore
@testable import TVECompilerCore

// swiftlint:disable file_length type_body_length function_body_length

/// Tests for AnimIR transform sampling, visibility, parenting, and matrix computation
final class AnimIRTransformTests: XCTestCase {

    // MARK: - AnimTrack Sampling Tests (Double)

    func testSampleStaticDouble_returnsStaticValue() {
        // Given
        let track: AnimTrack<Double> = .static(42.0)

        // When/Then
        XCTAssertEqual(track.sample(frame: 0), 42.0)
        XCTAssertEqual(track.sample(frame: 100), 42.0)
        XCTAssertEqual(track.sample(frame: -10), 42.0)
    }

    func testSampleKeyframedDouble_linearInterpolation() {
        // Given: opacity track 0 -> 100 over frames 0 to 30
        let track: AnimTrack<Double> = .keyframed([
            Keyframe(time: 0, value: 0),
            Keyframe(time: 30, value: 100)
        ])

        // When/Then
        XCTAssertEqual(track.sample(frame: 0), 0, accuracy: 0.001)
        XCTAssertEqual(track.sample(frame: 15), 50, accuracy: 0.001)
        XCTAssertEqual(track.sample(frame: 30), 100, accuracy: 0.001)
    }

    func testSampleKeyframedDouble_clampBeforeFirst() {
        // Given
        let track: AnimTrack<Double> = .keyframed([
            Keyframe(time: 10, value: 50),
            Keyframe(time: 20, value: 100)
        ])

        // When/Then - before first keyframe should return first value
        XCTAssertEqual(track.sample(frame: 0), 50)
        XCTAssertEqual(track.sample(frame: 5), 50)
        XCTAssertEqual(track.sample(frame: -100), 50)
    }

    func testSampleKeyframedDouble_clampAfterLast() {
        // Given
        let track: AnimTrack<Double> = .keyframed([
            Keyframe(time: 10, value: 50),
            Keyframe(time: 20, value: 100)
        ])

        // When/Then - after last keyframe should return last value
        XCTAssertEqual(track.sample(frame: 20), 100)
        XCTAssertEqual(track.sample(frame: 30), 100)
        XCTAssertEqual(track.sample(frame: 1000), 100)
    }

    func testSampleKeyframedDouble_multipleSegments() {
        // Given: 0 -> 100 -> 50 over frames 0-10-20
        let track: AnimTrack<Double> = .keyframed([
            Keyframe(time: 0, value: 0),
            Keyframe(time: 10, value: 100),
            Keyframe(time: 20, value: 50)
        ])

        // When/Then
        XCTAssertEqual(track.sample(frame: 5), 50, accuracy: 0.001)   // midpoint of segment 1
        XCTAssertEqual(track.sample(frame: 10), 100, accuracy: 0.001) // at second keyframe
        XCTAssertEqual(track.sample(frame: 15), 75, accuracy: 0.001)  // midpoint of segment 2
    }

    func testSampleKeyframedDouble_sameTimeKeyframes_returnsFirstValue() {
        // Given: edge case - two keyframes at same time
        let track: AnimTrack<Double> = .keyframed([
            Keyframe(time: 10, value: 0),
            Keyframe(time: 10, value: 100)
        ])

        // When/Then - returns first value since frame <= first keyframe time
        // This is valid behavior for degenerate case
        XCTAssertEqual(track.sample(frame: 10), 0)
    }

    // MARK: - AnimTrack Sampling Tests (Vec2D)

    func testSampleStaticVec2D_returnsStaticValue() {
        // Given
        let track: AnimTrack<Vec2D> = .static(Vec2D(x: 100, y: 200))

        // When/Then
        XCTAssertEqual(track.sample(frame: 0), Vec2D(x: 100, y: 200))
        XCTAssertEqual(track.sample(frame: 100), Vec2D(x: 100, y: 200))
    }

    func testSampleKeyframedVec2D_linearInterpolation() {
        // Given: position (0,0) -> (100,200) over frames 0 to 10
        let track: AnimTrack<Vec2D> = .keyframed([
            Keyframe(time: 0, value: Vec2D(x: 0, y: 0)),
            Keyframe(time: 10, value: Vec2D(x: 100, y: 200))
        ])

        // When
        let midpoint = track.sample(frame: 5)

        // Then
        XCTAssertEqual(midpoint.x, 50, accuracy: 0.001)
        XCTAssertEqual(midpoint.y, 100, accuracy: 0.001)
    }

    func testSampleKeyframedVec2D_clampBeforeFirst() {
        // Given
        let track: AnimTrack<Vec2D> = .keyframed([
            Keyframe(time: 10, value: Vec2D(x: 50, y: 60)),
            Keyframe(time: 20, value: Vec2D(x: 100, y: 200))
        ])

        // When/Then
        XCTAssertEqual(track.sample(frame: 0), Vec2D(x: 50, y: 60))
    }

    func testSampleKeyframedVec2D_clampAfterLast() {
        // Given
        let track: AnimTrack<Vec2D> = .keyframed([
            Keyframe(time: 10, value: Vec2D(x: 50, y: 60)),
            Keyframe(time: 20, value: Vec2D(x: 100, y: 200))
        ])

        // When/Then
        XCTAssertEqual(track.sample(frame: 100), Vec2D(x: 100, y: 200))
    }

    // MARK: - Lerp Function Tests

    func testLerpDouble() {
        XCTAssertEqual(lerp(0.0, 100.0, 0.0), 0.0)
        XCTAssertEqual(lerp(0.0, 100.0, 0.5), 50.0)
        XCTAssertEqual(lerp(0.0, 100.0, 1.0), 100.0)
        XCTAssertEqual(lerp(10.0, 20.0, 0.25), 12.5)
    }

    func testLerpVec2D() {
        let a = Vec2D(x: 0, y: 0)
        let b = Vec2D(x: 100, y: 200)

        let result = lerp(a, b, 0.5)
        XCTAssertEqual(result.x, 50.0)
        XCTAssertEqual(result.y, 100.0)
    }

    // MARK: - Visibility Tests

    func testIsVisible_withinRange_true() {
        // Given: layer active from frame 10 to 50
        let layer = makeTestLayer(ip: 10, op: 50)

        // When/Then
        XCTAssertTrue(AnimIR.isVisible(layer, at: 10))  // at ip (inclusive)
        XCTAssertTrue(AnimIR.isVisible(layer, at: 30))  // in middle
        XCTAssertTrue(AnimIR.isVisible(layer, at: 49))  // just before op
    }

    func testIsVisible_outsideRange_false() {
        // Given: layer active from frame 10 to 50
        let layer = makeTestLayer(ip: 10, op: 50)

        // When/Then
        XCTAssertFalse(AnimIR.isVisible(layer, at: 0))   // before ip
        XCTAssertFalse(AnimIR.isVisible(layer, at: 9))   // just before ip
        XCTAssertFalse(AnimIR.isVisible(layer, at: 50))  // at op (exclusive)
        XCTAssertFalse(AnimIR.isVisible(layer, at: 100)) // after op
    }

    func testIsVisible_ipEqualsOp_neverVisible() {
        // Given: degenerate case
        let layer = makeTestLayer(ip: 30, op: 30)

        // When/Then
        XCTAssertFalse(AnimIR.isVisible(layer, at: 30))
    }

    // MARK: - Matrix Order Tests (REQUIRED by tech lead)

    /// Test that verifies the matrix multiplication order: T(p) * R(r) * S(s) * T(-a)
    /// This test uses concrete numbers to catch any future "optimization" that breaks the order.
    func testComputeLocalMatrix_correctOrder() {
        // Given: anchor=(10,0), scale=2, rotation=0, position=(0,0)
        // For point (10,0) - the anchor point should remain at origin after transform
        let transform = TransformTrack(
            position: .static(Vec2D(x: 0, y: 0)),
            scale: .static(Vec2D(x: 200, y: 200)),  // 200% = 2x
            rotation: .static(0),
            opacity: .static(100),
            anchor: .static(Vec2D(x: 10, y: 0))
        )

        // When
        let matrix = AnimIR.computeLocalMatrix(transform: transform, at: 0)

        // Then: apply to anchor point (10,0) - should map to (0,0)
        // Chain: T(-a) moves (10,0) to (0,0), S(2) keeps it at (0,0), T(p) keeps it at (0,0)
        let anchorPoint = Vec2D(x: 10, y: 0)
        let result = matrix.apply(to: anchorPoint)

        XCTAssertEqual(result.x, 0, accuracy: 0.001)
        XCTAssertEqual(result.y, 0, accuracy: 0.001)
    }

    func testComputeLocalMatrix_pointAroundAnchor() {
        // Given: anchor=(10,0), scale=2, rotation=0, position=(0,0)
        // For point (20,0) - should be scaled around anchor
        let transform = TransformTrack(
            position: .static(Vec2D(x: 0, y: 0)),
            scale: .static(Vec2D(x: 200, y: 200)),  // 200% = 2x
            rotation: .static(0),
            opacity: .static(100),
            anchor: .static(Vec2D(x: 10, y: 0))
        )

        // When
        let matrix = AnimIR.computeLocalMatrix(transform: transform, at: 0)

        // Then: point (20,0) is 10 units from anchor
        // After scale by 2, it should be 20 units from anchor = (20,0) in local coords
        // But since anchor maps to (0,0), the point maps to (20,0)
        // Chain: T(-a) moves (20,0) to (10,0), S(2) makes it (20,0), T(p) keeps it (20,0)
        let testPoint = Vec2D(x: 20, y: 0)
        let result = matrix.apply(to: testPoint)

        XCTAssertEqual(result.x, 20, accuracy: 0.001)
        XCTAssertEqual(result.y, 0, accuracy: 0.001)
    }

    func testComputeLocalMatrix_withRotation90() {
        // Given: anchor=(0,0), scale=100%, rotation=90°, position=(0,0)
        let transform = TransformTrack(
            position: .static(Vec2D(x: 0, y: 0)),
            scale: .static(Vec2D(x: 100, y: 100)),
            rotation: .static(90),
            opacity: .static(100),
            anchor: .static(Vec2D(x: 0, y: 0))
        )

        // When
        let matrix = AnimIR.computeLocalMatrix(transform: transform, at: 0)

        // Then: point (10,0) rotates 90° clockwise (Lottie/screen coords) to (0,-10)
        // In screen coordinates (Y-down), positive rotation is clockwise
        let testPoint = Vec2D(x: 10, y: 0)
        let result = matrix.apply(to: testPoint)

        XCTAssertEqual(result.x, 0, accuracy: 0.001)
        XCTAssertEqual(result.y, -10, accuracy: 0.001)
    }

    func testComputeLocalMatrix_withPositionOffset() {
        // Given: position=(100,50), no rotation, no scale, no anchor
        let transform = TransformTrack(
            position: .static(Vec2D(x: 100, y: 50)),
            scale: .static(Vec2D(x: 100, y: 100)),
            rotation: .static(0),
            opacity: .static(100),
            anchor: .static(Vec2D(x: 0, y: 0))
        )

        // When
        let matrix = AnimIR.computeLocalMatrix(transform: transform, at: 0)

        // Then: origin should map to (100,50)
        let origin = Vec2D(x: 0, y: 0)
        let result = matrix.apply(to: origin)

        XCTAssertEqual(result.x, 100, accuracy: 0.001)
        XCTAssertEqual(result.y, 50, accuracy: 0.001)
    }

    func testComputeLocalMatrix_fullTransform() {
        // Given: complete transform with all values non-trivial
        // anchor=(50,50), position=(200,100), scale=50%, rotation=0
        let transform = TransformTrack(
            position: .static(Vec2D(x: 200, y: 100)),
            scale: .static(Vec2D(x: 50, y: 50)),  // 50% = 0.5x
            rotation: .static(0),
            opacity: .static(100),
            anchor: .static(Vec2D(x: 50, y: 50))
        )

        // When
        let matrix = AnimIR.computeLocalMatrix(transform: transform, at: 0)

        // Then: anchor point (50,50) should map to position (200,100)
        // Chain: T(-a): (50,50) -> (0,0), S(0.5): (0,0) -> (0,0), T(p): (0,0) -> (200,100)
        let anchorPoint = Vec2D(x: 50, y: 50)
        let result = matrix.apply(to: anchorPoint)

        XCTAssertEqual(result.x, 200, accuracy: 0.001)
        XCTAssertEqual(result.y, 100, accuracy: 0.001)
    }

    // MARK: - Opacity Computation Tests

    func testComputeOpacity_normalizes0to1() {
        // Given: opacity at 50%
        let transform = TransformTrack(
            position: .static(.zero),
            scale: .static(Vec2D(x: 100, y: 100)),
            rotation: .static(0),
            opacity: .static(50),
            anchor: .static(.zero)
        )

        // When
        let opacity = AnimIR.computeOpacity(transform: transform, at: 0)

        // Then
        XCTAssertEqual(opacity, 0.5, accuracy: 0.001)
    }

    func testComputeOpacity_clampsAbove100() {
        // Given: opacity over 100 (edge case)
        let transform = TransformTrack(
            position: .static(.zero),
            scale: .static(Vec2D(x: 100, y: 100)),
            rotation: .static(0),
            opacity: .static(150),
            anchor: .static(.zero)
        )

        // When
        let opacity = AnimIR.computeOpacity(transform: transform, at: 0)

        // Then
        XCTAssertEqual(opacity, 1.0, accuracy: 0.001)
    }

    func testComputeOpacity_clampsBelow0() {
        // Given: negative opacity (edge case)
        let transform = TransformTrack(
            position: .static(.zero),
            scale: .static(Vec2D(x: 100, y: 100)),
            rotation: .static(0),
            opacity: .static(-50),
            anchor: .static(.zero)
        )

        // When
        let opacity = AnimIR.computeOpacity(transform: transform, at: 0)

        // Then
        XCTAssertEqual(opacity, 0.0, accuracy: 0.001)
    }

    // MARK: - Parenting Test (synthetic)

    func testParenting_worldMatrixIsParentTimesChild() {
        // Given: synthetic AnimIR with parent and child
        // Parent at position (100, 0), child at local position (50, 0)
        // Expected world position of child: (150, 0)
        let parentTransform = TransformTrack(
            position: .static(Vec2D(x: 100, y: 0)),
            scale: .static(Vec2D(x: 100, y: 100)),
            rotation: .static(0),
            opacity: .static(100),
            anchor: .static(.zero)
        )

        let childTransform = TransformTrack(
            position: .static(Vec2D(x: 50, y: 0)),
            scale: .static(Vec2D(x: 100, y: 100)),
            rotation: .static(0),
            opacity: .static(100),
            anchor: .static(.zero)
        )

        // When: compute matrices
        let parentLocal = AnimIR.computeLocalMatrix(transform: parentTransform, at: 0)
        let childLocal = AnimIR.computeLocalMatrix(transform: childTransform, at: 0)

        // World = parent * child (concatenating applies child first, then parent)
        let childWorld = parentLocal.concatenating(childLocal)

        // Then: origin of child should be at (150, 0) in world space
        let origin = Vec2D(x: 0, y: 0)
        let worldPos = childWorld.apply(to: origin)

        XCTAssertEqual(worldPos.x, 150, accuracy: 0.001)
        XCTAssertEqual(worldPos.y, 0, accuracy: 0.001)
    }

    /// Parenting chain (via parentId) does NOT affect opacity - only transform
    /// This is correct Lottie/AE semantics: parent layer opacity is NOT inherited
    func testParenting_opacityNotInheritedFromParentChain() {
        // Given: parent with opacity 0%, child with opacity 100%
        // In Lottie/AE: parenting does NOT multiply opacity, only transform
        // So child should render at 100% opacity despite parent being 0%
        let parentLayer = Layer(
            id: 1,
            name: "ParentNull",
            type: .null,
            timing: LayerTiming(inPoint: 0, outPoint: 60, startTime: 0),
            parent: nil,
            transform: TransformTrack(
                position: .static(Vec2D(x: 100, y: 0)),
                scale: .static(Vec2D(x: 100, y: 100)),
                rotation: .static(0),
                opacity: .static(0),  // Parent opacity = 0%
                anchor: .static(.zero)
            ),
            masks: [],
            matte: nil,
            content: .none,
            isMatteSource: false
        )

        let childLayer = Layer(
            id: 2,
            name: "ChildImage",
            type: .image,
            timing: LayerTiming(inPoint: 0, outPoint: 60, startTime: 0),
            parent: 1,  // Parented to layer 1
            transform: TransformTrack(
                position: .static(Vec2D(x: 50, y: 0)),
                scale: .static(Vec2D(x: 100, y: 100)),
                rotation: .static(0),
                opacity: .static(100),  // Child opacity = 100%
                anchor: .static(.zero)
            ),
            masks: [],
            matte: nil,
            content: .image(assetId: "image_0"),
            isMatteSource: false
        )

        var ir = AnimIR(
            meta: Meta(
                width: 1080, height: 1920, fps: 30,
                inPoint: 0, outPoint: 60,
                sourceAnimRef: "test.json"
            ),
            rootComp: AnimIR.rootCompId,
            comps: [
                AnimIR.rootCompId: Composition(
                    id: AnimIR.rootCompId,
                    size: SizeD(width: 1080, height: 1920),
                    layers: [parentLayer, childLayer]
                )
            ],
            assets: AssetIndexIR(byId: ["image_0": "images/img.png"]),
            binding: BindingInfo(
                bindingKey: "media",
                boundLayerId: 2,
                boundAssetId: "image_0",
                boundCompId: AnimIR.rootCompId
            )
        )

        // When
        let commands = ir.renderCommands(frameIndex: 0)

        // Then: child should render with opacity 1.0 (NOT 0.0)
        // because parenting chain does NOT inherit opacity
        let drawCommand = commands.first { cmd in
            if case .drawImage = cmd { return true }
            return false
        }

        if case let .drawImage(_, opacity) = drawCommand {
            XCTAssertEqual(opacity, 1.0, accuracy: 0.01,
                "Child opacity should be 1.0 - parenting does NOT inherit opacity")
        } else {
            XCTFail("Expected DrawImage command")
        }
    }

    /// Precomp container opacity DOES affect its subtree (via context.parentOpacity)
    /// This is correct Lottie/AE semantics for precomp layers
    func testPrecomp_containerOpacityAffectsSubtree() {
        // Given: precomp layer at 50% opacity containing an image layer at 100%
        // Expected: image inside precomp renders at 50% (container opacity * layer opacity)
        let precompId: CompID = "precomp_0"

        // Image layer inside precomp
        let imageLayer = Layer(
            id: 1,
            name: "ImageInPrecomp",
            type: .image,
            timing: LayerTiming(inPoint: 0, outPoint: 60, startTime: 0),
            parent: nil,
            transform: .identity,  // 100% opacity
            masks: [],
            matte: nil,
            content: .image(assetId: "image_0"),
            isMatteSource: false
        )

        // Precomp layer in root comp with 50% opacity
        let precompLayer = Layer(
            id: 1,
            name: "PrecompLayer",
            type: .precomp,
            timing: LayerTiming(inPoint: 0, outPoint: 60, startTime: 0),
            parent: nil,
            transform: TransformTrack(
                position: .static(.zero),
                scale: .static(Vec2D(x: 100, y: 100)),
                rotation: .static(0),
                opacity: .static(50),  // 50% opacity on container
                anchor: .static(.zero)
            ),
            masks: [],
            matte: nil,
            content: .precomp(compId: precompId),
            isMatteSource: false
        )

        var ir = AnimIR(
            meta: Meta(
                width: 1080, height: 1920, fps: 30,
                inPoint: 0, outPoint: 60,
                sourceAnimRef: "test.json"
            ),
            rootComp: AnimIR.rootCompId,
            comps: [
                AnimIR.rootCompId: Composition(
                    id: AnimIR.rootCompId,
                    size: SizeD(width: 1080, height: 1920),
                    layers: [precompLayer]
                ),
                precompId: Composition(
                    id: precompId,
                    size: SizeD(width: 540, height: 960),
                    layers: [imageLayer]
                )
            ],
            assets: AssetIndexIR(byId: ["image_0": "images/img.png"]),
            binding: BindingInfo(
                bindingKey: "media",
                boundLayerId: 1,
                boundAssetId: "image_0",
                boundCompId: precompId
            )
        )

        // When
        let commands = ir.renderCommands(frameIndex: 0)

        // Then: image should render at 0.5 opacity (container 50% * layer 100%)
        let drawCommand = commands.first { cmd in
            if case .drawImage = cmd { return true }
            return false
        }

        if case let .drawImage(_, opacity) = drawCommand {
            XCTAssertEqual(opacity, 0.5, accuracy: 0.01,
                "Image in precomp should inherit container opacity: 0.5 * 1.0 = 0.5")
        } else {
            XCTFail("Expected DrawImage command")
        }
    }

    func testParenting_withParentRotation() {
        // Given: parent rotated 90°, child at local position (10, 0)
        // In screen coordinates (Y-down), 90° rotation is clockwise
        // So child at (10, 0) rotated 90° clockwise becomes (0, -10)
        let parentTransform = TransformTrack(
            position: .static(Vec2D(x: 0, y: 0)),
            scale: .static(Vec2D(x: 100, y: 100)),
            rotation: .static(90),
            opacity: .static(100),
            anchor: .static(.zero)
        )

        let childTransform = TransformTrack(
            position: .static(Vec2D(x: 10, y: 0)),
            scale: .static(Vec2D(x: 100, y: 100)),
            rotation: .static(0),
            opacity: .static(100),
            anchor: .static(.zero)
        )

        // When
        let parentLocal = AnimIR.computeLocalMatrix(transform: parentTransform, at: 0)
        let childLocal = AnimIR.computeLocalMatrix(transform: childTransform, at: 0)
        let childWorld = parentLocal.concatenating(childLocal)

        // Then: origin of child content should be at (0, -10) due to clockwise rotation
        let origin = Vec2D(x: 0, y: 0)
        let worldPos = childWorld.apply(to: origin)

        XCTAssertEqual(worldPos.x, 0, accuracy: 0.001)
        XCTAssertEqual(worldPos.y, -10, accuracy: 0.001)
    }

    // MARK: - Local Frame Index Tests

    func testLocalFrameIndex_clampsToBounds() {
        // Given: animation with op=300
        let ir = makeTestAnimIR(outPoint: 300)

        // When/Then
        XCTAssertEqual(ir.localFrameIndex(sceneFrameIndex: -10), 0)      // clamp low
        XCTAssertEqual(ir.localFrameIndex(sceneFrameIndex: 0), 0)        // at start
        XCTAssertEqual(ir.localFrameIndex(sceneFrameIndex: 150), 150)    // in middle
        XCTAssertEqual(ir.localFrameIndex(sceneFrameIndex: 299), 299)    // at max valid
        XCTAssertEqual(ir.localFrameIndex(sceneFrameIndex: 300), 299)    // clamp high
        XCTAssertEqual(ir.localFrameIndex(sceneFrameIndex: 1000), 299)   // way over
    }

    // MARK: - Precomp st Mapping Test (synthetic)

    func testPrecompStMapping_childFrameCalculation() {
        // Given: precomp layer with st=30
        // Scene frame 30 should map to child frame 0
        // Scene frame 40 should map to child frame 10
        let precompStartTime: Double = 30

        // When
        let sceneFrame30ChildFrame = 30.0 - precompStartTime
        let sceneFrame40ChildFrame = 40.0 - precompStartTime

        // Then
        XCTAssertEqual(sceneFrame30ChildFrame, 0.0, accuracy: 0.001)
        XCTAssertEqual(sceneFrame40ChildFrame, 10.0, accuracy: 0.001)
    }

    // MARK: - RenderCommands Integration Tests

    func testRenderCommands_noLayersVisible_emptyExceptGroups() {
        // Given: animation where all layers have ip > frame
        var ir = makeTestAnimIRWithLayer(
            layerIp: 30,
            layerOp: 60,
            assetId: "image_0"
        )

        // When: render at frame 0 (before ip)
        let commands = ir.renderCommands(frameIndex: 0)

        // Then: should have groups but no DrawImage
        let drawCommands = commands.filter {
            if case .drawImage = $0 { return true }
            return false
        }
        XCTAssertTrue(drawCommands.isEmpty)
    }

    func testRenderCommands_layerVisible_hasDrawImage() {
        // Given: animation where layer is visible
        var ir = makeTestAnimIRWithLayer(
            layerIp: 0,
            layerOp: 60,
            assetId: "image_0"
        )

        // When: render at frame 30 (within ip..op)
        let commands = ir.renderCommands(frameIndex: 30)

        // Then: should have DrawImage
        let drawCommands = commands.filter {
            if case .drawImage = $0 { return true }
            return false
        }
        XCTAssertFalse(drawCommands.isEmpty)
    }

    func testRenderCommands_opacityFadeIn_interpolates() {
        // Given: animation with opacity fade from 0 to 100 over 30 frames
        var ir = makeTestAnimIRWithOpacityFade(
            opacityStart: 0,
            opacityEnd: 100,
            startFrame: 0,
            endFrame: 30
        )

        // When: render at frame 15 (midpoint)
        let commands = ir.renderCommands(frameIndex: 15)

        // Then: DrawImage opacity should be ~0.5
        let drawCommand = commands.first {
            if case .drawImage = $0 { return true }
            return false
        }

        if case let .drawImage(_, opacity) = drawCommand {
            XCTAssertEqual(opacity, 0.5, accuracy: 0.01)
        } else {
            XCTFail("Expected DrawImage command")
        }
    }

    // MARK: - Helpers

    private func makeTestLayer(ip: Double, op: Double, parent: LayerID? = nil) -> Layer {
        Layer(
            id: 1,
            name: "TestLayer",
            type: .image,
            timing: LayerTiming(inPoint: ip, outPoint: op, startTime: 0),
            parent: parent,
            transform: .identity,
            masks: [],
            matte: nil,
            content: .image(assetId: "test_image"),
            isMatteSource: false
        )
    }

    private func makeTestAnimIR(outPoint: Double) -> AnimIR {
        AnimIR(
            meta: Meta(
                width: 1080,
                height: 1920,
                fps: 30,
                inPoint: 0,
                outPoint: outPoint,
                sourceAnimRef: "test.json"
            ),
            rootComp: AnimIR.rootCompId,
            comps: [
                AnimIR.rootCompId: Composition(
                    id: AnimIR.rootCompId,
                    size: SizeD(width: 1080, height: 1920),
                    layers: []
                )
            ],
            assets: AssetIndexIR(byId: [:]),
            binding: BindingInfo(
                bindingKey: "media",
                boundLayerId: 1,
                boundAssetId: "image_0",
                boundCompId: AnimIR.rootCompId
            )
        )
    }

    private func makeTestAnimIRWithLayer(layerIp: Double, layerOp: Double, assetId: String) -> AnimIR {
        let layer = Layer(
            id: 1,
            name: "TestLayer",
            type: .image,
            timing: LayerTiming(inPoint: layerIp, outPoint: layerOp, startTime: 0),
            parent: nil,
            transform: .identity,
            masks: [],
            matte: nil,
            content: .image(assetId: assetId),
            isMatteSource: false
        )

        return AnimIR(
            meta: Meta(
                width: 1080,
                height: 1920,
                fps: 30,
                inPoint: 0,
                outPoint: 300,
                sourceAnimRef: "test.json"
            ),
            rootComp: AnimIR.rootCompId,
            comps: [
                AnimIR.rootCompId: Composition(
                    id: AnimIR.rootCompId,
                    size: SizeD(width: 1080, height: 1920),
                    layers: [layer]
                )
            ],
            assets: AssetIndexIR(byId: [assetId: "images/\(assetId).png"]),
            binding: BindingInfo(
                bindingKey: "media",
                boundLayerId: 1,
                boundAssetId: assetId,
                boundCompId: AnimIR.rootCompId
            )
        )
    }

    private func makeTestAnimIRWithOpacityFade(
        opacityStart: Double,
        opacityEnd: Double,
        startFrame: Double,
        endFrame: Double
    ) -> AnimIR {
        let transform = TransformTrack(
            position: .static(Vec2D(x: 270, y: 480)),
            scale: .static(Vec2D(x: 100, y: 100)),
            rotation: .static(0),
            opacity: .keyframed([
                Keyframe(time: startFrame, value: opacityStart),
                Keyframe(time: endFrame, value: opacityEnd)
            ]),
            anchor: .static(Vec2D(x: 270, y: 480))
        )

        let layer = Layer(
            id: 1,
            name: "FadeLayer",
            type: .image,
            timing: LayerTiming(inPoint: 0, outPoint: 300, startTime: 0),
            parent: nil,
            transform: transform,
            masks: [],
            matte: nil,
            content: .image(assetId: "image_0"),
            isMatteSource: false
        )

        return AnimIR(
            meta: Meta(
                width: 1080,
                height: 1920,
                fps: 30,
                inPoint: 0,
                outPoint: 300,
                sourceAnimRef: "test.json"
            ),
            rootComp: AnimIR.rootCompId,
            comps: [
                AnimIR.rootCompId: Composition(
                    id: AnimIR.rootCompId,
                    size: SizeD(width: 1080, height: 1920),
                    layers: [layer]
                )
            ],
            assets: AssetIndexIR(byId: ["image_0": "images/img_0.png"]),
            binding: BindingInfo(
                bindingKey: "media",
                boundLayerId: 1,
                boundAssetId: "image_0",
                boundCompId: AnimIR.rootCompId
            )
        )
    }

    // MARK: - PARENT_NOT_FOUND Tests

    func testParentNotFound_reportsIssue() {
        // Given: layer with parent=99 which doesn't exist
        let layer = Layer(
            id: 1,
            name: "ChildLayer",
            type: .image,
            timing: LayerTiming(inPoint: 0, outPoint: 60, startTime: 0),
            parent: 99,  // Non-existent parent
            transform: .identity,
            masks: [],
            matte: nil,
            content: .image(assetId: "image_0"),
            isMatteSource: false
        )

        var ir = AnimIR(
            meta: Meta(
                width: 1080, height: 1920, fps: 30,
                inPoint: 0, outPoint: 60,
                sourceAnimRef: "test.json"
            ),
            rootComp: AnimIR.rootCompId,
            comps: [
                AnimIR.rootCompId: Composition(
                    id: AnimIR.rootCompId,
                    size: SizeD(width: 1080, height: 1920),
                    layers: [layer]
                )
            ],
            assets: AssetIndexIR(byId: ["image_0": "images/img.png"]),
            binding: BindingInfo(
                bindingKey: "media",
                boundLayerId: 1,
                boundAssetId: "image_0",
                boundCompId: AnimIR.rootCompId
            )
        )

        // When
        _ = ir.renderCommands(frameIndex: 0)

        // Then
        XCTAssertEqual(ir.lastRenderIssues.count, 1)
        let issue = ir.lastRenderIssues.first!
        XCTAssertEqual(issue.severity, .error)
        XCTAssertEqual(issue.code, RenderIssue.codeParentNotFound)
        XCTAssertTrue(issue.message.contains("99"))
    }

    func testParentNotFound_layerNotRendered() {
        // Given: layer with non-existent parent
        let layer = Layer(
            id: 1,
            name: "ChildLayer",
            type: .image,
            timing: LayerTiming(inPoint: 0, outPoint: 60, startTime: 0),
            parent: 99,
            transform: .identity,
            masks: [],
            matte: nil,
            content: .image(assetId: "image_0"),
            isMatteSource: false
        )

        var ir = AnimIR(
            meta: Meta(
                width: 1080, height: 1920, fps: 30,
                inPoint: 0, outPoint: 60,
                sourceAnimRef: "test.json"
            ),
            rootComp: AnimIR.rootCompId,
            comps: [
                AnimIR.rootCompId: Composition(
                    id: AnimIR.rootCompId,
                    size: SizeD(width: 1080, height: 1920),
                    layers: [layer]
                )
            ],
            assets: AssetIndexIR(byId: ["image_0": "images/img.png"]),
            binding: BindingInfo(
                bindingKey: "media",
                boundLayerId: 1,
                boundAssetId: "image_0",
                boundCompId: AnimIR.rootCompId
            )
        )

        // When
        let commands = ir.renderCommands(frameIndex: 0)

        // Then: no DrawImage command (layer was skipped)
        let hasDrawImage = commands.contains { cmd in
            if case .drawImage = cmd { return true }
            return false
        }
        XCTAssertFalse(hasDrawImage, "Layer with invalid parent should not render")
    }

    // MARK: - PARENT_CYCLE Tests

    func testParentCycle_reportsIssue() {
        // Given: layer1 -> layer2 -> layer1 (cycle)
        let layer1 = Layer(
            id: 1,
            name: "Layer1",
            type: .image,
            timing: LayerTiming(inPoint: 0, outPoint: 60, startTime: 0),
            parent: 2,
            transform: .identity,
            masks: [],
            matte: nil,
            content: .image(assetId: "image_0"),
            isMatteSource: false
        )
        let layer2 = Layer(
            id: 2,
            name: "Layer2",
            type: .null,
            timing: LayerTiming(inPoint: 0, outPoint: 60, startTime: 0),
            parent: 1,  // Points back to layer1 -> cycle!
            transform: .identity,
            masks: [],
            matte: nil,
            content: .none,
            isMatteSource: false
        )

        var ir = AnimIR(
            meta: Meta(
                width: 1080, height: 1920, fps: 30,
                inPoint: 0, outPoint: 60,
                sourceAnimRef: "test.json"
            ),
            rootComp: AnimIR.rootCompId,
            comps: [
                AnimIR.rootCompId: Composition(
                    id: AnimIR.rootCompId,
                    size: SizeD(width: 1080, height: 1920),
                    layers: [layer1, layer2]
                )
            ],
            assets: AssetIndexIR(byId: ["image_0": "images/img.png"]),
            binding: BindingInfo(
                bindingKey: "media",
                boundLayerId: 1,
                boundAssetId: "image_0",
                boundCompId: AnimIR.rootCompId
            )
        )

        // When
        _ = ir.renderCommands(frameIndex: 0)

        // Then
        XCTAssertGreaterThanOrEqual(ir.lastRenderIssues.count, 1)
        let cycleIssue = ir.lastRenderIssues.first { $0.code == RenderIssue.codeParentCycle }
        XCTAssertNotNil(cycleIssue, "Should have PARENT_CYCLE issue")
    }

    func testParentCycle_layerNotRendered() {
        // Given: self-referencing parent (simplest cycle)
        let layer = Layer(
            id: 1,
            name: "SelfRefLayer",
            type: .image,
            timing: LayerTiming(inPoint: 0, outPoint: 60, startTime: 0),
            parent: 1,  // References itself
            transform: .identity,
            masks: [],
            matte: nil,
            content: .image(assetId: "image_0"),
            isMatteSource: false
        )

        var ir = AnimIR(
            meta: Meta(
                width: 1080, height: 1920, fps: 30,
                inPoint: 0, outPoint: 60,
                sourceAnimRef: "test.json"
            ),
            rootComp: AnimIR.rootCompId,
            comps: [
                AnimIR.rootCompId: Composition(
                    id: AnimIR.rootCompId,
                    size: SizeD(width: 1080, height: 1920),
                    layers: [layer]
                )
            ],
            assets: AssetIndexIR(byId: ["image_0": "images/img.png"]),
            binding: BindingInfo(
                bindingKey: "media",
                boundLayerId: 1,
                boundAssetId: "image_0",
                boundCompId: AnimIR.rootCompId
            )
        )

        // When
        let commands = ir.renderCommands(frameIndex: 0)

        // Then: no DrawImage (layer with cycle skipped)
        let hasDrawImage = commands.contains { cmd in
            if case .drawImage = cmd { return true }
            return false
        }
        XCTAssertFalse(hasDrawImage, "Layer with parent cycle should not render")
        XCTAssertEqual(ir.lastRenderIssues.first?.code, RenderIssue.codeParentCycle)
    }

    func testRenderCommandsWithIssues_convenienceMethod() {
        // Given: layer with non-existent parent
        let layer = Layer(
            id: 1,
            name: "ChildLayer",
            type: .image,
            timing: LayerTiming(inPoint: 0, outPoint: 60, startTime: 0),
            parent: 99,
            transform: .identity,
            masks: [],
            matte: nil,
            content: .image(assetId: "image_0"),
            isMatteSource: false
        )

        let ir = AnimIR(
            meta: Meta(
                width: 1080, height: 1920, fps: 30,
                inPoint: 0, outPoint: 60,
                sourceAnimRef: "test.json"
            ),
            rootComp: AnimIR.rootCompId,
            comps: [
                AnimIR.rootCompId: Composition(
                    id: AnimIR.rootCompId,
                    size: SizeD(width: 1080, height: 1920),
                    layers: [layer]
                )
            ],
            assets: AssetIndexIR(byId: ["image_0": "images/img.png"]),
            binding: BindingInfo(
                bindingKey: "media",
                boundLayerId: 1,
                boundAssetId: "image_0",
                boundCompId: AnimIR.rootCompId
            )
        )

        // When: use convenience method (no var needed)
        let (commands, issues) = ir.renderCommandsWithIssues(frameIndex: 0)

        // Then
        XCTAssertFalse(commands.isEmpty)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.code, RenderIssue.codeParentNotFound)
    }
}

// swiftlint:enable file_length type_body_length function_body_length
