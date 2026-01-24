import XCTest
@testable import TVECore

final class SceneValidatorTests: XCTestCase {
    private var validator: SceneValidator!

    override func setUp() {
        super.setUp()
        validator = SceneValidator()
    }

    override func tearDown() {
        validator = nil
        super.tearDown()
    }

    // MARK: - Helper Methods

    private func makeValidScene() -> Scene {
        Scene(
            schemaVersion: "0.1",
            sceneId: "test_scene",
            canvas: Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 300),
            background: nil,
            mediaBlocks: [
                makeValidMediaBlock(id: "block_01")
            ]
        )
    }

    private func makeValidMediaBlock(id: String) -> MediaBlock {
        MediaBlock(
            id: id,
            zIndex: 0,
            rect: Rect(x: 0, y: 0, width: 540, height: 960),
            containerClip: .slotRect,
            timing: Timing(startFrame: 0, endFrame: 300),
            input: makeValidMediaInput(),
            variants: [makeValidVariant()]
        )
    }

    private func makeValidMediaInput() -> MediaInput {
        MediaInput(
            rect: Rect(x: 0, y: 0, width: 540, height: 960),
            bindingKey: "media",
            hitTest: .rect,
            allowedMedia: ["photo", "video", "color"],
            emptyPolicy: .hideWholeBlock,
            fitModesAllowed: [.cover, .contain],
            defaultFit: .cover,
            userTransformsAllowed: nil,
            audio: nil,
            maskRef: nil
        )
    }

    private func makeValidVariant() -> Variant {
        Variant(
            id: "v1",
            animRef: "anim-1.json",
            defaultDurationFrames: 300,
            ifAnimationShorter: .holdLastFrame,
            ifAnimationLonger: .cut,
            loop: false,
            loopRange: nil
        )
    }

    // MARK: - 6.1 Happy Path

    func testValidate_referenceScene_hasNoErrors() throws {
        let bundle = Bundle.module
        guard let sceneURL = bundle.url(
            forResource: "scene",
            withExtension: "json",
            subdirectory: "example_4blocks"
        ) else {
            XCTFail("Test scene.json not found in bundle")
            return
        }

        let data = try Data(contentsOf: sceneURL)
        let scene = try JSONDecoder().decode(Scene.self, from: data)

        let report = validator.validate(scene: scene)

        XCTAssertFalse(report.hasErrors, "Reference scene should have no errors")
    }

    func testValidate_validScene_hasNoErrors() {
        let scene = makeValidScene()
        let report = validator.validate(scene: scene)

        XCTAssertFalse(report.hasErrors)
        XCTAssertTrue(report.errors.isEmpty)
    }

    // MARK: - 6.2 Schema Version

    func testValidate_unsupportedVersion_returnsError() {
        var scene = makeValidScene()
        scene = Scene(
            schemaVersion: "2.0",
            sceneId: scene.sceneId,
            canvas: scene.canvas,
            background: scene.background,
            mediaBlocks: scene.mediaBlocks
        )

        let report = validator.validate(scene: scene)

        XCTAssertTrue(report.hasErrors)
        let error = report.errors.first { $0.code == SceneValidationCode.sceneUnsupportedVersion }
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.path, "$.schemaVersion")
    }

    // MARK: - 6.3 Canvas

    func testValidate_canvasWidthZero_returnsError() {
        let scene = Scene(
            schemaVersion: "0.1",
            sceneId: "test",
            canvas: Canvas(width: 0, height: 1920, fps: 30, durationFrames: 300),
            background: nil,
            mediaBlocks: [makeValidMediaBlock(id: "block_01")]
        )

        let report = validator.validate(scene: scene)

        XCTAssertTrue(report.hasErrors)
        let error = report.errors.first { $0.code == SceneValidationCode.canvasInvalidDimensions }
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.path, "$.canvas.width")
    }

    func testValidate_canvasHeightNegative_returnsError() {
        let scene = Scene(
            schemaVersion: "0.1",
            sceneId: "test",
            canvas: Canvas(width: 1080, height: -100, fps: 30, durationFrames: 300),
            background: nil,
            mediaBlocks: [makeValidMediaBlock(id: "block_01")]
        )

        let report = validator.validate(scene: scene)

        XCTAssertTrue(report.hasErrors)
        let error = report.errors.first { $0.code == SceneValidationCode.canvasInvalidDimensions }
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.path, "$.canvas.height")
    }

    func testValidate_canvasFpsZero_returnsError() {
        let scene = Scene(
            schemaVersion: "0.1",
            sceneId: "test",
            canvas: Canvas(width: 1080, height: 1920, fps: 0, durationFrames: 300),
            background: nil,
            mediaBlocks: [makeValidMediaBlock(id: "block_01")]
        )

        let report = validator.validate(scene: scene)

        XCTAssertTrue(report.hasErrors)
        let error = report.errors.first { $0.code == SceneValidationCode.canvasInvalidFPS }
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.path, "$.canvas.fps")
    }

    func testValidate_canvasDurationZero_returnsError() {
        let scene = Scene(
            schemaVersion: "0.1",
            sceneId: "test",
            canvas: Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 0),
            background: nil,
            mediaBlocks: [makeValidMediaBlock(id: "block_01")]
        )

        let report = validator.validate(scene: scene)

        XCTAssertTrue(report.hasErrors)
        let error = report.errors.first { $0.code == SceneValidationCode.canvasInvalidDuration }
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.path, "$.canvas.durationFrames")
    }

    // MARK: - 6.4 Blocks

    func testValidate_mediaBlocksEmpty_returnsError() {
        let scene = Scene(
            schemaVersion: "0.1",
            sceneId: "test",
            canvas: Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 300),
            background: nil,
            mediaBlocks: []
        )

        let report = validator.validate(scene: scene)

        XCTAssertTrue(report.hasErrors)
        let error = report.errors.first { $0.code == SceneValidationCode.blocksEmpty }
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.path, "$.mediaBlocks")
    }

    func testValidate_duplicateBlockId_returnsError() {
        let scene = Scene(
            schemaVersion: "0.1",
            sceneId: "test",
            canvas: Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 300),
            background: nil,
            mediaBlocks: [
                makeValidMediaBlock(id: "block_01"),
                makeValidMediaBlock(id: "block_01")
            ]
        )

        let report = validator.validate(scene: scene)

        XCTAssertTrue(report.hasErrors)
        let error = report.errors.first { $0.code == SceneValidationCode.blockIdDuplicate }
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.path, "$.mediaBlocks[1].blockId")
    }

    // MARK: - 6.5 Rect

    func testValidate_inputRectWidthZero_returnsError() {
        let input = MediaInput(
            rect: Rect(x: 0, y: 0, width: 0, height: 960),
            bindingKey: "media",
            hitTest: nil,
            allowedMedia: ["photo"],
            emptyPolicy: nil,
            fitModesAllowed: nil,
            defaultFit: nil,
            userTransformsAllowed: nil,
            audio: nil,
            maskRef: nil
        )
        let block = MediaBlock(
            id: "block_01",
            zIndex: 0,
            rect: Rect(x: 0, y: 0, width: 540, height: 960),
            containerClip: .slotRect,
            timing: nil,
            input: input,
            variants: [makeValidVariant()]
        )
        let scene = Scene(
            schemaVersion: "0.1",
            sceneId: "test",
            canvas: Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 300),
            background: nil,
            mediaBlocks: [block]
        )

        let report = validator.validate(scene: scene)

        XCTAssertTrue(report.hasErrors)
        let error = report.errors.first { $0.code == SceneValidationCode.rectInvalid }
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.path, "$.mediaBlocks[0].input.rect.width")
    }

    func testValidate_blockRectHeightNegative_returnsError() {
        let block = MediaBlock(
            id: "block_01",
            zIndex: 0,
            rect: Rect(x: 0, y: 0, width: 540, height: -1),
            containerClip: .slotRect,
            timing: nil,
            input: makeValidMediaInput(),
            variants: [makeValidVariant()]
        )
        let scene = Scene(
            schemaVersion: "0.1",
            sceneId: "test",
            canvas: Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 300),
            background: nil,
            mediaBlocks: [block]
        )

        let report = validator.validate(scene: scene)

        XCTAssertTrue(report.hasErrors)
        let error = report.errors.first { $0.code == SceneValidationCode.rectInvalid }
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.path, "$.mediaBlocks[0].rect.height")
    }

    // MARK: - Block Outside Canvas Warning

    func testValidate_blockOutsideCanvas_returnsWarning() {
        let block = MediaBlock(
            id: "block_01",
            zIndex: 0,
            rect: Rect(x: -100, y: 0, width: 540, height: 960),
            containerClip: .slotRect,
            timing: nil,
            input: makeValidMediaInput(),
            variants: [makeValidVariant()]
        )
        let scene = Scene(
            schemaVersion: "0.1",
            sceneId: "test",
            canvas: Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 300),
            background: nil,
            mediaBlocks: [block]
        )

        let report = validator.validate(scene: scene)

        XCTAssertFalse(report.hasErrors, "Should be warning, not error")
        let warning = report.warnings.first { $0.code == SceneValidationCode.blockOutsideCanvas }
        XCTAssertNotNil(warning)
        XCTAssertEqual(warning?.path, "$.mediaBlocks[0].rect")
    }

    func testValidate_blockExceedsCanvasRight_returnsWarning() {
        let block = MediaBlock(
            id: "block_01",
            zIndex: 0,
            rect: Rect(x: 800, y: 0, width: 540, height: 960),
            containerClip: .slotRect,
            timing: nil,
            input: makeValidMediaInput(),
            variants: [makeValidVariant()]
        )
        let scene = Scene(
            schemaVersion: "0.1",
            sceneId: "test",
            canvas: Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 300),
            background: nil,
            mediaBlocks: [block]
        )

        let report = validator.validate(scene: scene)

        XCTAssertFalse(report.hasErrors)
        let warning = report.warnings.first { $0.code == SceneValidationCode.blockOutsideCanvas }
        XCTAssertNotNil(warning, "Block at x=800 with width=540 exceeds canvas width=1080")
    }

    // MARK: - 6.6 Variants

    func testValidate_variantsEmpty_returnsError() {
        let block = MediaBlock(
            id: "block_01",
            zIndex: 0,
            rect: Rect(x: 0, y: 0, width: 540, height: 960),
            containerClip: .slotRect,
            timing: nil,
            input: makeValidMediaInput(),
            variants: []
        )
        let scene = Scene(
            schemaVersion: "0.1",
            sceneId: "test",
            canvas: Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 300),
            background: nil,
            mediaBlocks: [block]
        )

        let report = validator.validate(scene: scene)

        XCTAssertTrue(report.hasErrors)
        let error = report.errors.first { $0.code == SceneValidationCode.variantsEmpty }
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.path, "$.mediaBlocks[0].variants")
    }

    func testValidate_variantAnimRefEmpty_returnsError() {
        let variant = Variant(
            id: "v1",
            animRef: "",
            defaultDurationFrames: nil,
            ifAnimationShorter: nil,
            ifAnimationLonger: nil,
            loop: nil,
            loopRange: nil
        )
        let block = MediaBlock(
            id: "block_01",
            zIndex: 0,
            rect: Rect(x: 0, y: 0, width: 540, height: 960),
            containerClip: .slotRect,
            timing: nil,
            input: makeValidMediaInput(),
            variants: [variant]
        )
        let scene = Scene(
            schemaVersion: "0.1",
            sceneId: "test",
            canvas: Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 300),
            background: nil,
            mediaBlocks: [block]
        )

        let report = validator.validate(scene: scene)

        XCTAssertTrue(report.hasErrors)
        let error = report.errors.first { $0.code == SceneValidationCode.variantAnimRefEmpty }
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.path, "$.mediaBlocks[0].variants[0].animRef")
    }

    // MARK: - 6.7 BindingKey

    func testValidate_bindingKeyEmpty_returnsError() {
        let input = MediaInput(
            rect: Rect(x: 0, y: 0, width: 540, height: 960),
            bindingKey: "",
            hitTest: nil,
            allowedMedia: ["photo"],
            emptyPolicy: nil,
            fitModesAllowed: nil,
            defaultFit: nil,
            userTransformsAllowed: nil,
            audio: nil,
            maskRef: nil
        )
        let block = MediaBlock(
            id: "block_01",
            zIndex: 0,
            rect: Rect(x: 0, y: 0, width: 540, height: 960),
            containerClip: .slotRect,
            timing: nil,
            input: input,
            variants: [makeValidVariant()]
        )
        let scene = Scene(
            schemaVersion: "0.1",
            sceneId: "test",
            canvas: Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 300),
            background: nil,
            mediaBlocks: [block]
        )

        let report = validator.validate(scene: scene)

        XCTAssertTrue(report.hasErrors)
        let error = report.errors.first { $0.code == SceneValidationCode.inputBindingKeyEmpty }
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.path, "$.mediaBlocks[0].input.bindingKey")
    }

    // MARK: - 6.8 ContainerClip

    func testValidate_containerClipUnsupported_returnsError() {
        let block = MediaBlock(
            id: "block_01",
            zIndex: 0,
            rect: Rect(x: 0, y: 0, width: 540, height: 960),
            containerClip: .slotRectAfterSettle,
            timing: nil,
            input: makeValidMediaInput(),
            variants: [makeValidVariant()]
        )
        let scene = Scene(
            schemaVersion: "0.1",
            sceneId: "test",
            canvas: Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 300),
            background: nil,
            mediaBlocks: [block]
        )

        let report = validator.validate(scene: scene)

        XCTAssertTrue(report.hasErrors)
        let error = report.errors.first { $0.code == SceneValidationCode.containerClipUnsupported }
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.path, "$.mediaBlocks[0].containerClip")
    }

    // MARK: - 6.9 AllowedMedia

    func testValidate_allowedMediaEmpty_returnsError() {
        let input = MediaInput(
            rect: Rect(x: 0, y: 0, width: 540, height: 960),
            bindingKey: "media",
            hitTest: nil,
            allowedMedia: [],
            emptyPolicy: nil,
            fitModesAllowed: nil,
            defaultFit: nil,
            userTransformsAllowed: nil,
            audio: nil,
            maskRef: nil
        )
        let block = MediaBlock(
            id: "block_01",
            zIndex: 0,
            rect: Rect(x: 0, y: 0, width: 540, height: 960),
            containerClip: .slotRect,
            timing: nil,
            input: input,
            variants: [makeValidVariant()]
        )
        let scene = Scene(
            schemaVersion: "0.1",
            sceneId: "test",
            canvas: Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 300),
            background: nil,
            mediaBlocks: [block]
        )

        let report = validator.validate(scene: scene)

        XCTAssertTrue(report.hasErrors)
        let error = report.errors.first { $0.code == SceneValidationCode.allowedMediaEmpty }
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.path, "$.mediaBlocks[0].input.allowedMedia")
    }

    func testValidate_allowedMediaInvalidValue_returnsError() {
        let input = MediaInput(
            rect: Rect(x: 0, y: 0, width: 540, height: 960),
            bindingKey: "media",
            hitTest: nil,
            allowedMedia: ["photo", "banana"],
            emptyPolicy: nil,
            fitModesAllowed: nil,
            defaultFit: nil,
            userTransformsAllowed: nil,
            audio: nil,
            maskRef: nil
        )
        let block = MediaBlock(
            id: "block_01",
            zIndex: 0,
            rect: Rect(x: 0, y: 0, width: 540, height: 960),
            containerClip: .slotRect,
            timing: nil,
            input: input,
            variants: [makeValidVariant()]
        )
        let scene = Scene(
            schemaVersion: "0.1",
            sceneId: "test",
            canvas: Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 300),
            background: nil,
            mediaBlocks: [block]
        )

        let report = validator.validate(scene: scene)

        XCTAssertTrue(report.hasErrors)
        let error = report.errors.first { $0.code == SceneValidationCode.allowedMediaInvalidValue }
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.path, "$.mediaBlocks[0].input.allowedMedia[1]")
    }

    func testValidate_allowedMediaDuplicate_returnsError() {
        let input = MediaInput(
            rect: Rect(x: 0, y: 0, width: 540, height: 960),
            bindingKey: "media",
            hitTest: nil,
            allowedMedia: ["photo", "photo"],
            emptyPolicy: nil,
            fitModesAllowed: nil,
            defaultFit: nil,
            userTransformsAllowed: nil,
            audio: nil,
            maskRef: nil
        )
        let block = MediaBlock(
            id: "block_01",
            zIndex: 0,
            rect: Rect(x: 0, y: 0, width: 540, height: 960),
            containerClip: .slotRect,
            timing: nil,
            input: input,
            variants: [makeValidVariant()]
        )
        let scene = Scene(
            schemaVersion: "0.1",
            sceneId: "test",
            canvas: Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 300),
            background: nil,
            mediaBlocks: [block]
        )

        let report = validator.validate(scene: scene)

        XCTAssertTrue(report.hasErrors)
        let error = report.errors.first { $0.code == SceneValidationCode.allowedMediaDuplicate }
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.path, "$.mediaBlocks[0].input.allowedMedia[1]")
    }

    // MARK: - 6.10 Timing

    func testValidate_timingStartEqualsEnd_returnsError() {
        let block = MediaBlock(
            id: "block_01",
            zIndex: 0,
            rect: Rect(x: 0, y: 0, width: 540, height: 960),
            containerClip: .slotRect,
            timing: Timing(startFrame: 10, endFrame: 10),
            input: makeValidMediaInput(),
            variants: [makeValidVariant()]
        )
        let scene = Scene(
            schemaVersion: "0.1",
            sceneId: "test",
            canvas: Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 300),
            background: nil,
            mediaBlocks: [block]
        )

        let report = validator.validate(scene: scene)

        XCTAssertTrue(report.hasErrors)
        let error = report.errors.first { $0.code == SceneValidationCode.timingInvalidRange }
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.path, "$.mediaBlocks[0].timing")
    }

    func testValidate_timingEndExceedsDuration_returnsError() {
        let block = MediaBlock(
            id: "block_01",
            zIndex: 0,
            rect: Rect(x: 0, y: 0, width: 540, height: 960),
            containerClip: .slotRect,
            timing: Timing(startFrame: 0, endFrame: 500),
            input: makeValidMediaInput(),
            variants: [makeValidVariant()]
        )
        let scene = Scene(
            schemaVersion: "0.1",
            sceneId: "test",
            canvas: Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 300),
            background: nil,
            mediaBlocks: [block]
        )

        let report = validator.validate(scene: scene)

        XCTAssertTrue(report.hasErrors)
        let error = report.errors.first { $0.code == SceneValidationCode.timingInvalidRange }
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.path, "$.mediaBlocks[0].timing")
    }

    // MARK: - Variant Duration

    func testValidate_variantDefaultDurationZero_returnsError() {
        let variant = Variant(
            id: "v1",
            animRef: "anim-1.json",
            defaultDurationFrames: 0,
            ifAnimationShorter: nil,
            ifAnimationLonger: nil,
            loop: nil,
            loopRange: nil
        )
        let block = MediaBlock(
            id: "block_01",
            zIndex: 0,
            rect: Rect(x: 0, y: 0, width: 540, height: 960),
            containerClip: .slotRect,
            timing: nil,
            input: makeValidMediaInput(),
            variants: [variant]
        )
        let scene = Scene(
            schemaVersion: "0.1",
            sceneId: "test",
            canvas: Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 300),
            background: nil,
            mediaBlocks: [block]
        )

        let report = validator.validate(scene: scene)

        XCTAssertTrue(report.hasErrors)
        let error = report.errors.first { $0.code == SceneValidationCode.variantDefaultDurationInvalid }
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.path, "$.mediaBlocks[0].variants[0].defaultDurationFrames")
    }

    func testValidate_variantLoopRangeInvalid_returnsError() {
        let variant = Variant(
            id: "v1",
            animRef: "anim-1.json",
            defaultDurationFrames: 300,
            ifAnimationShorter: nil,
            ifAnimationLonger: nil,
            loop: true,
            loopRange: LoopRange(startFrame: 100, endFrame: 50)
        )
        let block = MediaBlock(
            id: "block_01",
            zIndex: 0,
            rect: Rect(x: 0, y: 0, width: 540, height: 960),
            containerClip: .slotRect,
            timing: nil,
            input: makeValidMediaInput(),
            variants: [variant]
        )
        let scene = Scene(
            schemaVersion: "0.1",
            sceneId: "test",
            canvas: Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 300),
            background: nil,
            mediaBlocks: [block]
        )

        let report = validator.validate(scene: scene)

        XCTAssertTrue(report.hasErrors)
        let error = report.errors.first { $0.code == SceneValidationCode.variantLoopRangeInvalid }
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.path, "$.mediaBlocks[0].variants[0].loopRange")
    }

    // MARK: - MaskRef Warning

    func testValidate_maskRefWithoutCatalog_returnsWarning() {
        let input = MediaInput(
            rect: Rect(x: 0, y: 0, width: 540, height: 960),
            bindingKey: "media",
            hitTest: nil,
            allowedMedia: ["photo"],
            emptyPolicy: nil,
            fitModesAllowed: nil,
            defaultFit: nil,
            userTransformsAllowed: nil,
            audio: nil,
            maskRef: "circle_mask"
        )
        let block = MediaBlock(
            id: "block_01",
            zIndex: 0,
            rect: Rect(x: 0, y: 0, width: 540, height: 960),
            containerClip: .slotRect,
            timing: nil,
            input: input,
            variants: [makeValidVariant()]
        )
        let scene = Scene(
            schemaVersion: "0.1",
            sceneId: "test",
            canvas: Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 300),
            background: nil,
            mediaBlocks: [block]
        )

        let report = validator.validate(scene: scene)

        XCTAssertFalse(report.hasErrors)
        let warning = report.warnings.first { $0.code == SceneValidationCode.maskRefCatalogUnavailable }
        XCTAssertNotNil(warning)
        XCTAssertEqual(warning?.path, "$.mediaBlocks[0].input.maskRef")
    }

    func testValidate_maskRefNotFound_returnsWarning() {
        let mockCatalog = MockMaskCatalog(masks: ["other_mask"])
        let validatorWithCatalog = SceneValidator(maskCatalog: mockCatalog)

        let input = MediaInput(
            rect: Rect(x: 0, y: 0, width: 540, height: 960),
            bindingKey: "media",
            hitTest: nil,
            allowedMedia: ["photo"],
            emptyPolicy: nil,
            fitModesAllowed: nil,
            defaultFit: nil,
            userTransformsAllowed: nil,
            audio: nil,
            maskRef: "circle_mask"
        )
        let block = MediaBlock(
            id: "block_01",
            zIndex: 0,
            rect: Rect(x: 0, y: 0, width: 540, height: 960),
            containerClip: .slotRect,
            timing: nil,
            input: input,
            variants: [makeValidVariant()]
        )
        let scene = Scene(
            schemaVersion: "0.1",
            sceneId: "test",
            canvas: Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 300),
            background: nil,
            mediaBlocks: [block]
        )

        let report = validatorWithCatalog.validate(scene: scene)

        XCTAssertFalse(report.hasErrors)
        let warning = report.warnings.first { $0.code == SceneValidationCode.maskRefNotFound }
        XCTAssertNotNil(warning)
        XCTAssertEqual(warning?.path, "$.mediaBlocks[0].input.maskRef")
    }
}

// MARK: - Mock MaskCatalog

private final class MockMaskCatalog: MaskCatalog {
    private let masks: Set<String>

    init(masks: [String]) {
        self.masks = Set(masks)
    }

    func contains(maskRef: String) -> Bool {
        masks.contains(maskRef)
    }
}
