import XCTest
@testable import TVECore

// MARK: - PR-17: Hit-Test & Editor Overlay Tests
//
// Validates:
// T1 — SceneTransforms.blockTransform ≡ old computeBlockTransform (refactor invariance)
// T2 — BezierPath.cgPath + contains(point:)
// T3 — mediaInputHitPath returns correct canvas-space path
// T4 — hitTest: mask vs rect modes, z-order, invisible blocks
// T5 — overlays: top-to-bottom order, hitPath geometry, rect fallback

final class HitTestOverlayTests: XCTestCase {

    // MARK: - Helpers

    private var compiler: AnimIRCompiler!

    override func setUp() {
        super.setUp()
        compiler = AnimIRCompiler()
    }

    override func tearDown() {
        compiler = nil
        super.tearDown()
    }

    /// Decodes a JSON string into LottieJSON
    private func decodeLottie(_ json: String) throws -> LottieJSON {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(LottieJSON.self, from: data)
    }

    /// Minimal 100×100 closed rect path vertices
    private static let rectPathJSON = """
    { "a": 0, "k": {
        "v": [[0,0],[100,0],[100,100],[0,100]],
        "i": [[0,0],[0,0],[0,0],[0,0]],
        "o": [[0,0],[0,0],[0,0],[0,0]],
        "c": true
    }}
    """

    /// Builds a Lottie JSON (1080×1920) with mediaInput (shape layer) + binding layer (media).
    private func lottieJSON(width: Int = 1080, height: Int = 1920) -> String {
        """
        {
          "fr": 30, "ip": 0, "op": 300, "w": \(width), "h": \(height),
          "assets": [
            { "id": "image_0", "w": 540, "h": 960, "u": "images/", "p": "img.png", "e": 0 }
          ],
          "layers": [
            {
              "ty": 4, "ind": 10, "nm": "mediaInput",
              "hd": true,
              "shapes": [
                { "ty": "gr", "it": [
                  { "ty": "sh", "ks": \(Self.rectPathJSON) },
                  { "ty": "fl", "c": { "a": 0, "k": [0,0,0,1] }, "o": { "a": 0, "k": 100 } }
                ]}
              ],
              "ks": {
                "o": { "a": 0, "k": 100 },
                "r": { "a": 0, "k": 0 },
                "p": { "a": 0, "k": [0, 0, 0] },
                "a": { "a": 0, "k": [0, 0, 0] },
                "s": { "a": 0, "k": [100, 100, 100] }
              },
              "ip": 0, "op": 300, "st": 0
            },
            {
              "ty": 2, "ind": 1, "nm": "media", "refId": "image_0",
              "ks": {
                "o": { "a": 0, "k": 100 },
                "r": { "a": 0, "k": 0 },
                "p": { "a": 0, "k": [270, 480, 0] },
                "a": { "a": 0, "k": [270, 480, 0] },
                "s": { "a": 0, "k": [100, 100, 100] }
              },
              "ip": 0, "op": 300, "st": 0
            }
          ]
        }
        """
    }

    /// No-anim animRef used for edit-variant in test scenes.
    private static let noAnimRef = "no-anim-test"

    /// Creates a single-block ScenePackage with configurable hitTestMode.
    private func makeScenePackage(
        lottieJSON json: String,
        blockId: String = "block-1",
        animRef: String = "anim-test",
        hitTestMode: HitTestMode? = nil,
        blockRect: Rect = Rect(x: 0, y: 0, width: 1080, height: 1920),
        canvasWidth: Int = 1080,
        canvasHeight: Int = 1920
    ) throws -> (ScenePackage, LoadedAnimations) {
        let lottie = try decodeLottie(json)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])

        let scene = Scene(
            schemaVersion: "0.1",
            sceneId: "test-scene",
            canvas: Canvas(width: canvasWidth, height: canvasHeight, fps: 30, durationFrames: 300),
            mediaBlocks: [
                MediaBlock(
                    id: blockId,
                    zIndex: 0,
                    rect: blockRect,
                    containerClip: .slotRect,
                    input: MediaInput(
                        rect: blockRect,
                        bindingKey: "media",
                        hitTest: hitTestMode,
                        allowedMedia: ["photo"]
                    ),
                    variants: [
                        Variant(id: "v1", animRef: animRef),
                        Variant(id: "no-anim", animRef: Self.noAnimRef)
                    ]
                )
            ]
        )

        let package = ScenePackage(
            rootURL: URL(fileURLWithPath: "/tmp"),
            scene: scene,
            animFilesByRef: [:],
            imagesRootURL: nil
        )

        let animations = LoadedAnimations(
            lottieByAnimRef: [
                animRef: lottie,
                Self.noAnimRef: lottie
            ],
            assetIndexByAnimRef: [
                animRef: assetIndex,
                Self.noAnimRef: assetIndex
            ]
        )

        return (package, animations)
    }

    /// Creates a two-block scene with different zIndex and optional hitTestMode per block.
    private func makeTwoBlockScene(
        hitTestA: HitTestMode? = nil,
        hitTestB: HitTestMode? = nil,
        timingB: Timing? = nil
    ) throws -> (ScenePackage, LoadedAnimations) {
        let json = lottieJSON()
        let lottie = try decodeLottie(json)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])

        let scene = Scene(
            schemaVersion: "0.1",
            sceneId: "test-scene-2blocks",
            canvas: Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 300),
            mediaBlocks: [
                MediaBlock(
                    id: "block-A",
                    zIndex: 0,
                    rect: Rect(x: 0, y: 0, width: 1080, height: 960),
                    containerClip: .slotRect,
                    input: MediaInput(
                        rect: Rect(x: 0, y: 0, width: 1080, height: 960),
                        bindingKey: "media",
                        hitTest: hitTestA,
                        allowedMedia: ["photo"]
                    ),
                    variants: [
                        Variant(id: "v1", animRef: "anim-test"),
                        Variant(id: "no-anim", animRef: Self.noAnimRef)
                    ]
                ),
                MediaBlock(
                    id: "block-B",
                    zIndex: 1,
                    rect: Rect(x: 0, y: 0, width: 1080, height: 1920),
                    containerClip: .slotRect,
                    timing: timingB,
                    input: MediaInput(
                        rect: Rect(x: 0, y: 0, width: 1080, height: 1920),
                        bindingKey: "media",
                        hitTest: hitTestB,
                        allowedMedia: ["photo"]
                    ),
                    variants: [
                        Variant(id: "v1", animRef: "anim-test"),
                        Variant(id: "no-anim", animRef: Self.noAnimRef)
                    ]
                )
            ]
        )

        let package = ScenePackage(
            rootURL: URL(fileURLWithPath: "/tmp"),
            scene: scene,
            animFilesByRef: [:],
            imagesRootURL: nil
        )

        let animations = LoadedAnimations(
            lottieByAnimRef: [
                "anim-test": lottie,
                Self.noAnimRef: lottie
            ],
            assetIndexByAnimRef: [
                "anim-test": assetIndex,
                Self.noAnimRef: assetIndex
            ]
        )

        return (package, animations)
    }

    // MARK: - T1: SceneTransforms.blockTransform (Refactor Invariance Micro-Test)

    /// SceneTransforms.blockTransform must produce the same result as the old private
    /// SceneRenderPlan.computeBlockTransform for identical inputs.
    func testT1_blockTransform_fullCanvasIsIdentity() {
        let animSize = SizeD(width: 1080, height: 1920)
        let canvasSize = SizeD(width: 1080, height: 1920)
        let blockRect = RectD(x: 0, y: 0, width: 1080, height: 1920)

        let result = SceneTransforms.blockTransform(
            animSize: animSize,
            blockRect: blockRect,
            canvasSize: canvasSize
        )

        XCTAssertEqual(result, .identity,
            "Full-canvas animation must produce identity transform")
    }

    /// Non-full-canvas animation must produce a non-identity contain transform
    func testT1_blockTransform_smallAnimProducesContain() {
        let animSize = SizeD(width: 540, height: 960)
        let canvasSize = SizeD(width: 1080, height: 1920)
        let blockRect = RectD(x: 0, y: 480, width: 1080, height: 960)

        let result = SceneTransforms.blockTransform(
            animSize: animSize,
            blockRect: blockRect,
            canvasSize: canvasSize
        )

        // Must NOT be identity (anim is 540×960, canvas is 1080×1920)
        XCTAssertNotEqual(result, .identity,
            "Small animation must produce non-identity blockTransform")

        // Verify it matches GeometryMapping.animToInputContain
        let expected = GeometryMapping.animToInputContain(animSize: animSize, inputRect: blockRect)
        XCTAssertEqual(result, expected,
            "blockTransform must match GeometryMapping.animToInputContain")
    }

    /// Refactoring invariance: render commands are identical before & after
    /// extracting computeBlockTransform to SceneTransforms.
    func testT1_blockTransform_renderCommandsUnchanged() throws {
        let json = lottieJSON()
        let (package, animations) = try makeScenePackage(lottieJSON: json)

        let player = ScenePlayer()
        try player.compile(package: package, loadedAnimations: animations)

        let commands = player.renderCommands(sceneFrameIndex: 0)
        XCTAssertFalse(commands.isEmpty)
        XCTAssertTrue(commands.isBalanced())

        // For full-canvas anim: block transform should be identity
        let pushTransforms = commands.compactMap { cmd -> Matrix2D? in
            if case .pushTransform(let m) = cmd { return m }
            return nil
        }
        // First pushTransform in the block group is the blockTransform
        XCTAssertTrue(pushTransforms.contains(.identity),
            "Full-canvas animation block must have identity blockTransform")
    }

    /// Near-equal anim/canvas sizes still produce identity (floating-point tolerance)
    func testT1_blockTransform_nearlyEqualSizesAreIdentity() {
        let animSize = SizeD(width: 1080.00001, height: 1919.99999)
        let canvasSize = SizeD(width: 1080, height: 1920)
        let blockRect = RectD(x: 0, y: 0, width: 1080, height: 1920)

        let result = SceneTransforms.blockTransform(
            animSize: animSize,
            blockRect: blockRect,
            canvasSize: canvasSize
        )

        XCTAssertEqual(result, .identity,
            "Nearly-equal anim/canvas sizes must produce identity (tolerance)")
    }

    // MARK: - T2: BezierPath.cgPath + contains(point:)

    /// Closed rectangular BezierPath → cgPath → contains works for inside/outside points
    func testT2_cgPath_closedRect_containsPoint() {
        // 100×100 rect at origin
        let path = BezierPath(
            vertices: [
                Vec2D(x: 0, y: 0),
                Vec2D(x: 100, y: 0),
                Vec2D(x: 100, y: 100),
                Vec2D(x: 0, y: 100)
            ],
            inTangents: [.zero, .zero, .zero, .zero],
            outTangents: [.zero, .zero, .zero, .zero],
            closed: true
        )

        // Inside
        XCTAssertTrue(path.contains(point: Vec2D(x: 50, y: 50)),
            "Center of rect must be inside")
        XCTAssertTrue(path.contains(point: Vec2D(x: 1, y: 1)),
            "Near top-left corner must be inside")
        XCTAssertTrue(path.contains(point: Vec2D(x: 99, y: 99)),
            "Near bottom-right corner must be inside")

        // Outside
        XCTAssertFalse(path.contains(point: Vec2D(x: -1, y: 50)),
            "Left of rect must be outside")
        XCTAssertFalse(path.contains(point: Vec2D(x: 150, y: 50)),
            "Right of rect must be outside")
        XCTAssertFalse(path.contains(point: Vec2D(x: 50, y: -1)),
            "Above rect must be outside")
        XCTAssertFalse(path.contains(point: Vec2D(x: 50, y: 101)),
            "Below rect must be outside")
    }

    /// Open path → contains always returns false
    func testT2_cgPath_openPath_neverContains() {
        let path = BezierPath(
            vertices: [
                Vec2D(x: 0, y: 0),
                Vec2D(x: 100, y: 0),
                Vec2D(x: 100, y: 100),
                Vec2D(x: 0, y: 100)
            ],
            inTangents: [.zero, .zero, .zero, .zero],
            outTangents: [.zero, .zero, .zero, .zero],
            closed: false  // open!
        )

        XCTAssertFalse(path.contains(point: Vec2D(x: 50, y: 50)),
            "Open path must never contain a point")
    }

    /// Empty path → cgPath is valid but empty
    func testT2_cgPath_emptyPath() {
        let path = BezierPath.empty
        XCTAssertFalse(path.contains(point: Vec2D(x: 0, y: 0)),
            "Empty path must never contain a point")
    }

    /// Path with curved segments (ellipse) → cgPath contains works
    func testT2_cgPath_ellipse_containsCenter() {
        // 4-point ellipse approximation (100×100 centered at 50,50)
        let kappa = 0.5522847498307936
        let rx = 50.0, ry = 50.0
        let cx = 50.0, cy = 50.0
        let cpx = rx * kappa, cpy = ry * kappa

        let path = BezierPath(
            vertices: [
                Vec2D(x: cx, y: cy - ry),     // top
                Vec2D(x: cx + rx, y: cy),      // right
                Vec2D(x: cx, y: cy + ry),      // bottom
                Vec2D(x: cx - rx, y: cy)       // left
            ],
            inTangents: [
                Vec2D(x: -cpx, y: 0),
                Vec2D(x: 0, y: -cpy),
                Vec2D(x: cpx, y: 0),
                Vec2D(x: 0, y: cpy)
            ],
            outTangents: [
                Vec2D(x: cpx, y: 0),
                Vec2D(x: 0, y: cpy),
                Vec2D(x: -cpx, y: 0),
                Vec2D(x: 0, y: -cpy)
            ],
            closed: true
        )

        // Center
        XCTAssertTrue(path.contains(point: Vec2D(x: 50, y: 50)),
            "Center of ellipse must be inside")

        // Far outside corner
        XCTAssertFalse(path.contains(point: Vec2D(x: 0, y: 0)),
            "Corner of bounding box must be outside ellipse")
    }

    /// BezierPath.applying transforms path, and contains respects the new coordinates
    func testT2_cgPath_transformedPath_containsShifted() {
        let path = BezierPath(
            vertices: [
                Vec2D(x: 0, y: 0),
                Vec2D(x: 100, y: 0),
                Vec2D(x: 100, y: 100),
                Vec2D(x: 0, y: 100)
            ],
            inTangents: [.zero, .zero, .zero, .zero],
            outTangents: [.zero, .zero, .zero, .zero],
            closed: true
        )

        // Translate path by (200, 300)
        let shifted = path.applying(.translation(x: 200, y: 300))

        // Original center (50,50) should no longer be inside
        XCTAssertFalse(shifted.contains(point: Vec2D(x: 50, y: 50)),
            "Original center must be outside after translation")

        // New center (250, 350) should be inside
        XCTAssertTrue(shifted.contains(point: Vec2D(x: 250, y: 350)),
            "Translated center must be inside")
    }

    // MARK: - T3: mediaInputHitPath

    /// Full-canvas anim → mediaInputHitPath returns the mediaInput shape as-is (identity blockTransform)
    func testT3_mediaInputHitPath_fullCanvasAnim() throws {
        let json = lottieJSON(width: 1080, height: 1920)
        let (package, animations) = try makeScenePackage(
            lottieJSON: json, hitTestMode: .mask
        )

        let player = ScenePlayer()
        try player.compile(package: package, loadedAnimations: animations)

        let hitPath = player.mediaInputHitPath(blockId: "block-1", frame: 0)
        XCTAssertNotNil(hitPath, "mediaInputHitPath must return a path for block with mediaInput")

        // The mediaInput shape is a 100×100 rect at origin (identity world transform, identity blockTransform)
        // So the hit path should be approximately a 100×100 rect
        if let hp = hitPath {
            XCTAssertEqual(hp.vertexCount, 4, "Hit path must have 4 vertices (rect)")
            XCTAssertTrue(hp.closed, "Hit path must be closed")
        }
    }

    /// Nonexistent blockId → returns nil
    func testT3_mediaInputHitPath_unknownBlockId() throws {
        let json = lottieJSON()
        let (package, animations) = try makeScenePackage(lottieJSON: json)

        let player = ScenePlayer()
        try player.compile(package: package, loadedAnimations: animations)

        let hitPath = player.mediaInputHitPath(blockId: "nonexistent", frame: 0)
        XCTAssertNil(hitPath, "Unknown blockId must return nil")
    }

    /// Before compilation → returns nil
    func testT3_mediaInputHitPath_beforeCompile() {
        let player = ScenePlayer()
        let hitPath = player.mediaInputHitPath(blockId: "block-1", frame: 0)
        XCTAssertNil(hitPath, "Before compilation must return nil")
    }

    // MARK: - T4: hitTest

    /// hitTestMode == .rect → hit-test by block rect
    func testT4_hitTest_rectMode_insideBlockRect() throws {
        let json = lottieJSON()
        let (package, animations) = try makeScenePackage(
            lottieJSON: json,
            hitTestMode: .rect,
            blockRect: Rect(x: 100, y: 200, width: 500, height: 500)
        )

        let player = ScenePlayer()
        try player.compile(package: package, loadedAnimations: animations)

        // Inside block rect
        let hit = player.hitTest(point: Vec2D(x: 350, y: 450), frame: 0)
        XCTAssertEqual(hit, "block-1", "Point inside block rect must hit")

        // Outside block rect
        let miss = player.hitTest(point: Vec2D(x: 50, y: 50), frame: 0)
        XCTAssertNil(miss, "Point outside block rect must miss")
    }

    /// hitTestMode == nil → falls back to rect hit-test
    func testT4_hitTest_nilMode_fallsBackToRect() throws {
        let json = lottieJSON()
        let (package, animations) = try makeScenePackage(
            lottieJSON: json,
            hitTestMode: nil,
            blockRect: Rect(x: 0, y: 0, width: 1080, height: 1920)
        )

        let player = ScenePlayer()
        try player.compile(package: package, loadedAnimations: animations)

        // Inside
        let hit = player.hitTest(point: Vec2D(x: 540, y: 960), frame: 0)
        XCTAssertEqual(hit, "block-1", "nil hitTestMode must fall back to rect")

        // Outside
        let miss = player.hitTest(point: Vec2D(x: -1, y: -1), frame: 0)
        XCTAssertNil(miss, "Point outside rect must miss")
    }

    /// hitTestMode == .mask → hit-test by mediaInput shape
    func testT4_hitTest_maskMode_usesShape() throws {
        // mediaInput shape is a 100×100 rect at origin
        // block rect is full canvas 1080×1920
        let json = lottieJSON()
        let (package, animations) = try makeScenePackage(
            lottieJSON: json,
            hitTestMode: .mask
        )

        let player = ScenePlayer()
        try player.compile(package: package, loadedAnimations: animations)

        // Inside the mediaInput shape (50,50 is inside 100×100 rect at origin)
        let hitInside = player.hitTest(point: Vec2D(x: 50, y: 50), frame: 0)
        XCTAssertEqual(hitInside, "block-1",
            "Point inside mediaInput shape must hit in mask mode")

        // Outside the mediaInput shape but inside block rect (e.g. 500, 500)
        let hitOutsideShape = player.hitTest(point: Vec2D(x: 500, y: 500), frame: 0)
        XCTAssertNil(hitOutsideShape,
            "Point outside mediaInput shape must miss in mask mode even if inside block rect")
    }

    /// Z-order: topmost block wins (highest zIndex first)
    func testT4_hitTest_zOrder_topmostWins() throws {
        let (package, animations) = try makeTwoBlockScene(
            hitTestA: .rect,  // zIndex 0, top half (0,0,1080,960)
            hitTestB: .rect   // zIndex 1, full canvas (0,0,1080,1920) — overlaps A
        )

        let player = ScenePlayer()
        try player.compile(package: package, loadedAnimations: animations)

        // Point in overlap zone (540, 480) — block-B (zIndex 1) should win
        let hit = player.hitTest(point: Vec2D(x: 540, y: 480), frame: 0)
        XCTAssertEqual(hit, "block-B",
            "Higher zIndex block must win in overlap zone")

        // Point below block-A's rect but inside block-B (540, 1200)
        let hitBottom = player.hitTest(point: Vec2D(x: 540, y: 1200), frame: 0)
        XCTAssertEqual(hitBottom, "block-B",
            "Only block-B covers the bottom area")
    }

    /// Invisible block is skipped by hitTest
    func testT4_hitTest_invisibleBlock_skipped() throws {
        // block-B has timing that makes it invisible at frame 0
        let (package, animations) = try makeTwoBlockScene(
            hitTestA: .rect,
            hitTestB: .rect,
            timingB: Timing(startFrame: 100, endFrame: 200)  // invisible at frame 0
        )

        let player = ScenePlayer()
        try player.compile(package: package, loadedAnimations: animations)

        // Point in block-B area but B is invisible → should hit A (if inside A's rect)
        // block-A rect: (0,0,1080,960)
        let hit = player.hitTest(point: Vec2D(x: 540, y: 480), frame: 0)
        XCTAssertEqual(hit, "block-A",
            "Invisible block-B must be skipped; block-A should be hit")
    }

    /// Before compilation → hitTest returns nil
    func testT4_hitTest_beforeCompile() {
        let player = ScenePlayer()
        let hit = player.hitTest(point: Vec2D(x: 100, y: 100), frame: 0)
        XCTAssertNil(hit, "hitTest before compilation must return nil")
    }

    // MARK: - T5: overlays

    /// Overlays returns descriptors for all visible blocks in top-to-bottom order
    func testT5_overlays_topToBottomOrder() throws {
        let (package, animations) = try makeTwoBlockScene(
            hitTestA: .rect,
            hitTestB: .rect
        )

        let player = ScenePlayer()
        try player.compile(package: package, loadedAnimations: animations)

        let overlays = player.overlays(frame: 0)

        XCTAssertEqual(overlays.count, 2, "Two visible blocks → two overlays")

        // Top-to-bottom: block-B (zIndex 1) first, then block-A (zIndex 0)
        XCTAssertEqual(overlays[0].blockId, "block-B",
            "First overlay must be highest zIndex block")
        XCTAssertEqual(overlays[1].blockId, "block-A",
            "Second overlay must be lower zIndex block")
    }

    /// Overlay hitPath for .mask mode uses mediaInput shape
    func testT5_overlays_maskMode_usesShapePath() throws {
        let json = lottieJSON()
        let (package, animations) = try makeScenePackage(
            lottieJSON: json,
            hitTestMode: .mask
        )

        let player = ScenePlayer()
        try player.compile(package: package, loadedAnimations: animations)

        let overlays = player.overlays(frame: 0)
        XCTAssertEqual(overlays.count, 1)

        let overlay = overlays[0]
        XCTAssertEqual(overlay.blockId, "block-1")

        // hitPath should be the mediaInput shape (4 vertices for the 100×100 rect)
        XCTAssertEqual(overlay.hitPath.vertexCount, 4,
            "Mask mode overlay hitPath must be from mediaInput shape")
        XCTAssertTrue(overlay.hitPath.closed)
    }

    /// Overlay hitPath for .rect mode (or nil) uses block rect as path
    func testT5_overlays_rectMode_usesBlockRect() throws {
        let json = lottieJSON()
        let blockRect = Rect(x: 100, y: 200, width: 500, height: 600)
        let (package, animations) = try makeScenePackage(
            lottieJSON: json,
            hitTestMode: .rect,
            blockRect: blockRect
        )

        let player = ScenePlayer()
        try player.compile(package: package, loadedAnimations: animations)

        let overlays = player.overlays(frame: 0)
        XCTAssertEqual(overlays.count, 1)

        let overlay = overlays[0]
        // hitPath should be block rect converted to BezierPath (4 vertices)
        XCTAssertEqual(overlay.hitPath.vertexCount, 4)
        XCTAssertTrue(overlay.hitPath.closed)

        // Verify the rect geometry: top-left should be at (100, 200)
        let vertices = overlay.hitPath.vertices
        XCTAssertEqual(vertices[0].x, 100, accuracy: 0.001)
        XCTAssertEqual(vertices[0].y, 200, accuracy: 0.001)
        // bottom-right at (600, 800)
        XCTAssertEqual(vertices[2].x, 600, accuracy: 0.001)
        XCTAssertEqual(vertices[2].y, 800, accuracy: 0.001)

        // rectCanvas should be stored
        XCTAssertEqual(overlay.rectCanvas.x, 100, accuracy: 0.001)
        XCTAssertEqual(overlay.rectCanvas.width, 500, accuracy: 0.001)
    }

    /// Invisible blocks are excluded from overlays
    func testT5_overlays_invisibleBlock_excluded() throws {
        let (package, animations) = try makeTwoBlockScene(
            hitTestA: .rect,
            hitTestB: .rect,
            timingB: Timing(startFrame: 100, endFrame: 200)  // invisible at frame 0
        )

        let player = ScenePlayer()
        try player.compile(package: package, loadedAnimations: animations)

        let overlays = player.overlays(frame: 0)
        XCTAssertEqual(overlays.count, 1, "Only visible blocks should have overlays")
        XCTAssertEqual(overlays[0].blockId, "block-A")
    }

    /// Before compilation → overlays returns empty array
    func testT5_overlays_beforeCompile() {
        let player = ScenePlayer()
        let overlays = player.overlays(frame: 0)
        XCTAssertTrue(overlays.isEmpty)
    }

    // MARK: - hitTestMode Propagation

    /// hitTestMode from MediaInput is correctly propagated to BlockRuntime
    func testHitTestMode_propagatedToBlockRuntime() throws {
        let json = lottieJSON()
        let (package, animations) = try makeScenePackage(
            lottieJSON: json,
            hitTestMode: .mask
        )

        let player = ScenePlayer()
        let compiled = try player.compile(package: package, loadedAnimations: animations)

        let block = compiled.runtime.blocks.first
        XCTAssertEqual(block?.hitTestMode, .mask,
            "hitTestMode must be propagated from MediaInput to BlockRuntime")
    }

    /// hitTestMode nil when MediaInput has no hitTest specified
    func testHitTestMode_nilWhenNotSpecified() throws {
        let json = lottieJSON()
        let (package, animations) = try makeScenePackage(
            lottieJSON: json,
            hitTestMode: nil
        )

        let player = ScenePlayer()
        let compiled = try player.compile(package: package, loadedAnimations: animations)

        let block = compiled.runtime.blocks.first
        XCTAssertNil(block?.hitTestMode,
            "hitTestMode must be nil when not specified in MediaInput")
    }

    // MARK: - Backwards Compatibility

    /// Existing BlockRuntime init without hitTestMode still compiles (default nil)
    func testBackwardsCompat_blockRuntimeDefaultHitTestMode() {
        let block = BlockRuntime(
            blockId: "test",
            zIndex: 0,
            orderIndex: 0,
            rectCanvas: RectD(x: 0, y: 0, width: 100, height: 100),
            inputRect: RectD(x: 0, y: 0, width: 100, height: 100),
            timing: BlockTiming(startFrame: 0, endFrame: 100),
            containerClip: .slotRect,
            selectedVariantId: "v1",
            editVariantId: "no-anim",
            variants: []
        )

        XCTAssertNil(block.hitTestMode,
            "Default hitTestMode must be nil for backwards compat")
    }

    /// Existing render pipeline still works after SceneRenderPlan refactoring
    func testBackwardsCompat_renderCommandsUnchanged() throws {
        let json = lottieJSON()
        let (package, animations) = try makeScenePackage(lottieJSON: json)

        let player = ScenePlayer()
        try player.compile(package: package, loadedAnimations: animations)

        // Render without any hit-test API calls
        let commands = player.renderCommands(sceneFrameIndex: 0)
        XCTAssertFalse(commands.isEmpty)
        XCTAssertTrue(commands.isBalanced())
    }

}
