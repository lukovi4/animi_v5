import XCTest
@testable import TVECore
@testable import TVECompilerCore

// MARK: - MediaInput Tests (PR-15)

final class MediaInputTests: XCTestCase {
    var compiler: AnimIRCompiler!
    private var _testRegistry = PathRegistry()

    override func setUp() {
        super.setUp()
        compiler = AnimIRCompiler()
    }

    override func tearDown() {
        compiler = nil
        super.tearDown()
    }

    // MARK: - JSON Helpers

    private func decodeLottie(_ json: String) throws -> LottieJSON {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(LottieJSON.self, from: data)
    }

    /// Minimal shape path vertices for a 100x100 rectangle at origin
    private static let rectPathJSON = """
    { "a": 0, "k": {
        "v": [[0,0],[100,0],[100,100],[0,100]],
        "i": [[0,0],[0,0],[0,0],[0,0]],
        "o": [[0,0],[0,0],[0,0],[0,0]],
        "c": true
    }}
    """

    /// Builds a JSON for mediaInput shape layer (ty=4) with specified properties
    private func mediaInputLayerJSON(
        name: String = "mediaInput",
        type: Int = 4,
        index: Int = 10,
        hidden: Bool = true,
        shapePath: String = MediaInputTests.rectPathJSON,
        extraShapes: String = "",
        parentId: Int? = nil
    ) -> String {
        let hdPart = hidden ? "\"hd\": true," : ""
        let parentPart = parentId.map { "\"parent\": \($0)," } ?? ""
        return """
        {
          "ty": \(type),
          "ind": \(index),
          "nm": "\(name)",
          \(hdPart)
          \(parentPart)
          "shapes": [
            { "ty": "gr", "it": [
              { "ty": "sh", "ks": \(shapePath) },
              { "ty": "fl", "c": { "a": 0, "k": [0,0,0,1] }, "o": { "a": 0, "k": 100 } }
              \(extraShapes)
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
        }
        """
    }

    /// Builds a complete Lottie JSON with mediaInput in a precomp alongside the binding layer
    private func lottieWithMediaInput(
        mediaInputLayer: String? = nil,
        extraPrecompLayers: String = "",
        mediaInRoot: Bool = false
    ) -> String {
        let defaultMediaInput = mediaInputLayerJSON()
        let miLayer = mediaInputLayer ?? defaultMediaInput

        if mediaInRoot {
            // Both media and mediaInput in root composition
            return """
            {
              "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
              "assets": [
                { "id": "image_0", "w": 540, "h": 960, "u": "images/", "p": "img.png", "e": 0 }
              ],
              "layers": [
                \(miLayer),
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
                \(extraPrecompLayers)
              ]
            }
            """
        }

        // mediaInput and media in same precomp
        return """
        {
          "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
          "assets": [
            { "id": "image_0", "w": 540, "h": 960, "u": "images/", "p": "img.png", "e": 0 },
            {
              "id": "comp_0", "nm": "precomp", "fr": 30,
              "layers": [
                \(miLayer),
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
                \(extraPrecompLayers)
              ]
            }
          ],
          "layers": [
            {
              "ty": 0, "ind": 1, "nm": "precomp_layer", "refId": "comp_0",
              "ks": {
                "o": { "a": 0, "k": 100 },
                "r": { "a": 0, "k": 0 },
                "p": { "a": 0, "k": [540, 960, 0] },
                "a": { "a": 0, "k": [540, 960, 0] },
                "s": { "a": 0, "k": [100, 100, 100] }
              },
              "w": 1080, "h": 1920,
              "ip": 0, "op": 300, "st": 0
            }
          ]
        }
        """
    }

    // MARK: - Compiler: mediaInput Detection

    func testCompile_withMediaInput_createsInputGeometry() throws {
        // Given: precomp with mediaInput (ty=4, hd=true) and binding layer
        let json = lottieWithMediaInput()
        let lottie = try decodeLottie(json)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])

        // When
        let ir = try compiler.compile(
            lottie: lottie,
            animRef: "test",
            bindingKey: "media",
            assetIndex: assetIndex,
            pathRegistry: &_testRegistry
        )

        // Then
        XCTAssertNotNil(ir.inputGeometry, "inputGeometry should be populated when mediaInput exists")
        XCTAssertEqual(ir.inputGeometry?.layerId, 10)
        XCTAssertEqual(ir.inputGeometry?.compId, "comp_0")
    }

    func testCompile_withMediaInputInRoot_createsInputGeometry() throws {
        // Given: root comp with mediaInput and binding layer
        let json = lottieWithMediaInput(mediaInRoot: true)
        let lottie = try decodeLottie(json)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])

        // When
        let ir = try compiler.compile(
            lottie: lottie,
            animRef: "test",
            bindingKey: "media",
            assetIndex: assetIndex,
            pathRegistry: &_testRegistry
        )

        // Then
        XCTAssertNotNil(ir.inputGeometry)
        XCTAssertEqual(ir.inputGeometry?.compId, AnimIR.rootCompId)
    }

    func testCompile_withoutMediaInput_inputGeometryIsNil() throws {
        // Given: no mediaInput layer
        let json = """
        {
          "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
          "assets": [{ "id": "image_0", "w": 540, "h": 960, "u": "images/", "p": "img.png", "e": 0 }],
          "layers": [
            { "ty": 2, "ind": 1, "nm": "media", "refId": "image_0",
              "ks": { "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
                      "p": { "a": 0, "k": [0,0,0] }, "a": { "a": 0, "k": [0,0,0] },
                      "s": { "a": 0, "k": [100,100,100] } },
              "ip": 0, "op": 300, "st": 0
            }
          ]
        }
        """
        let lottie = try decodeLottie(json)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])

        // When
        let ir = try compiler.compile(
            lottie: lottie,
            animRef: "test",
            bindingKey: "media",
            assetIndex: assetIndex,
            pathRegistry: &_testRegistry
        )

        // Then
        XCTAssertNil(ir.inputGeometry)
    }

    // MARK: - Compiler: Hidden Layer

    func testCompile_hiddenLayer_isHiddenTrue() throws {
        // Given: mediaInput with hd=true
        let json = lottieWithMediaInput()
        let lottie = try decodeLottie(json)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])

        // When
        let ir = try compiler.compile(
            lottie: lottie,
            animRef: "test",
            bindingKey: "media",
            assetIndex: assetIndex,
            pathRegistry: &_testRegistry
        )

        // Then: find the mediaInput layer in precomp
        guard let precomp = ir.comps["comp_0"] else {
            XCTFail("precomp not found")
            return
        }
        let mediaInputLayer = precomp.layers.first { $0.name == "mediaInput" }
        XCTAssertNotNil(mediaInputLayer)
        XCTAssertTrue(mediaInputLayer?.isHidden ?? false, "mediaInput layer should have isHidden=true")
    }

    func testCompile_nonHiddenLayer_isHiddenFalse() throws {
        // Given: binding layer without hd flag
        let json = lottieWithMediaInput()
        let lottie = try decodeLottie(json)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])

        // When
        let ir = try compiler.compile(
            lottie: lottie,
            animRef: "test",
            bindingKey: "media",
            assetIndex: assetIndex,
            pathRegistry: &_testRegistry
        )

        // Then
        guard let precomp = ir.comps["comp_0"] else {
            XCTFail("precomp not found")
            return
        }
        let mediaLayer = precomp.layers.first { $0.name == "media" }
        XCTAssertNotNil(mediaLayer)
        XCTAssertFalse(mediaLayer?.isHidden ?? true, "media layer should have isHidden=false")
    }

    // MARK: - Compiler: Same-Comp Constraint

    func testCompile_mediaInputInDifferentComp_throws() throws {
        // Given: mediaInput in root, binding layer (media) in precomp
        let json = """
        {
          "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
          "assets": [
            { "id": "image_0", "w": 540, "h": 960, "u": "images/", "p": "img.png", "e": 0 },
            { "id": "comp_0", "nm": "precomp", "fr": 30,
              "layers": [
                { "ty": 2, "ind": 1, "nm": "media", "refId": "image_0",
                  "ks": { "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
                          "p": { "a": 0, "k": [0,0,0] }, "a": { "a": 0, "k": [0,0,0] },
                          "s": { "a": 0, "k": [100,100,100] } },
                  "ip": 0, "op": 300, "st": 0
                }
              ]
            }
          ],
          "layers": [
            \(mediaInputLayerJSON()),
            { "ty": 0, "ind": 1, "nm": "precomp_layer", "refId": "comp_0",
              "ks": { "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
                      "p": { "a": 0, "k": [0,0,0] }, "a": { "a": 0, "k": [0,0,0] },
                      "s": { "a": 0, "k": [100,100,100] } },
              "w": 1080, "h": 1920,
              "ip": 0, "op": 300, "st": 0
            }
          ]
        }
        """
        let lottie = try decodeLottie(json)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])

        // When/Then
        XCTAssertThrowsError(try compiler.compile(
            lottie: lottie,
            animRef: "test",
            bindingKey: "media",
            assetIndex: assetIndex,
            pathRegistry: &_testRegistry
        )) { error in
            guard case AnimIRCompilerError.mediaInputNotInSameComp = error else {
                XCTFail("Expected mediaInputNotInSameComp, got \(error)")
                return
            }
        }
    }

    // MARK: - Compiler: PathRegistry

    func testCompile_mediaInput_registersPathInRegistry() throws {
        // Given
        let json = lottieWithMediaInput()
        let lottie = try decodeLottie(json)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])
        var registry = PathRegistry()

        // When
        let ir = try compiler.compile(
            lottie: lottie,
            animRef: "test",
            bindingKey: "media",
            assetIndex: assetIndex,
            pathRegistry: &registry
        )

        // Then
        XCTAssertNotNil(ir.inputGeometry?.pathId, "mediaInput pathId should be assigned")
        // Path should be registered in the shared registry
        XCTAssertTrue(registry.count > 0, "PathRegistry should have at least one path registered")
    }

    // MARK: - Render Commands: Hidden Layer Skipped

    func testRender_hiddenLayer_notRendered() throws {
        // Given: mediaInput (hd=true) in root comp with media layer
        let json = lottieWithMediaInput(mediaInRoot: true)
        let lottie = try decodeLottie(json)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])

        // When
        var ir = try compiler.compile(
            lottie: lottie,
            animRef: "test",
            bindingKey: "media",
            assetIndex: assetIndex,
            pathRegistry: &_testRegistry
        )
        let commands = ir.renderCommands(frameIndex: 0)

        // Then: should not have drawShape for the hidden mediaInput layer
        let drawShapeCommands = commands.filter {
            if case .drawShape = $0 { return true }
            return false
        }
        // mediaInput is hidden → no drawShape for it
        XCTAssertEqual(drawShapeCommands.count, 0,
            "Hidden mediaInput layer should not generate drawShape commands")

        // But there should be a drawImage for the media binding layer
        let drawImageCommands = commands.filter {
            if case .drawImage = $0 { return true }
            return false
        }
        XCTAssertEqual(drawImageCommands.count, 1,
            "Media binding layer should still generate drawImage")
    }

    // MARK: - Render Commands: InputClip Structure

    func testRender_withInputClip_generatesCorrectCommandStructure() throws {
        // Given: precomp with mediaInput + media
        let json = lottieWithMediaInput()
        let lottie = try decodeLottie(json)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])

        // When
        var ir = try compiler.compile(
            lottie: lottie,
            animRef: "test",
            bindingKey: "media",
            assetIndex: assetIndex,
            pathRegistry: &_testRegistry
        )
        let commands = ir.renderCommands(frameIndex: 0)

        // Then: the binding layer should have inputClip structure
        // Expected pattern:
        //   beginGroup(Layer:media(...))
        //     pushTransform(mediaInputWorld)
        //     beginMask(mode: .intersect, ...)  ← inputClip
        //     popTransform
        //     pushTransform(mediaWorldWithUser)
        //       drawImage(...)
        //     popTransform
        //     endMask
        //   endGroup

        // Find the media layer group
        let mediaGroupIdx = commands.firstIndex {
            if case .beginGroup(let name) = $0 { return name.contains("media") && name.contains("Layer:") }
            return false
        }
        XCTAssertNotNil(mediaGroupIdx, "Should have beginGroup for media layer")

        guard let startIdx = mediaGroupIdx else { return }

        // After the media beginGroup, the first mask should be the inputClip (intersect)
        let firstMaskAfterGroup = commands[startIdx...].first {
            if case .beginMask(let mode, _, _, _, _) = $0 { return mode == .intersect }
            return false
        }
        XCTAssertNotNil(firstMaskAfterGroup, "Should have beginMask(.intersect) for inputClip")

        // Check there's a drawImage command inside
        let drawImageInScope = commands[startIdx...].contains {
            if case .drawImage = $0 { return true }
            return false
        }
        XCTAssertTrue(drawImageInScope, "Should have drawImage inside inputClip scope")
    }

    func testRender_withInputClip_hasMatchedMaskPairs() throws {
        // Given
        let json = lottieWithMediaInput()
        let lottie = try decodeLottie(json)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])

        // When
        var ir = try compiler.compile(
            lottie: lottie,
            animRef: "test",
            bindingKey: "media",
            assetIndex: assetIndex,
            pathRegistry: &_testRegistry
        )
        let commands = ir.renderCommands(frameIndex: 0)

        // Then: beginMask count == endMask count
        let beginMaskCount = commands.filter {
            if case .beginMask = $0 { return true }
            return false
        }.count

        let endMaskCount = commands.filter {
            if case .endMask = $0 { return true }
            return false
        }.count

        XCTAssertEqual(beginMaskCount, endMaskCount,
            "beginMask and endMask counts must match (got \(beginMaskCount) vs \(endMaskCount))")
        XCTAssertGreaterThan(beginMaskCount, 0, "Should have at least one mask (inputClip)")
    }

    // MARK: - Render Commands: UserTransform

    func testRender_userTransform_appliedToBindingLayer() throws {
        // Given: media in root with mediaInput
        let json = lottieWithMediaInput(mediaInRoot: true)
        let lottie = try decodeLottie(json)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])

        // When: render with identity and with a custom userTransform
        var ir = try compiler.compile(
            lottie: lottie,
            animRef: "test",
            bindingKey: "media",
            assetIndex: assetIndex,
            pathRegistry: &_testRegistry
        )

        let cmdsIdentity = ir.renderCommands(frameIndex: 0, userTransform: .identity)
        let userShift = Matrix2D.translation(x: 50, y: 100)
        let cmdsShifted = ir.renderCommands(frameIndex: 0, userTransform: userShift)

        // Then: commands should differ (the pushTransform matrices should differ)
        let pushTransformsIdentity = cmdsIdentity.compactMap { cmd -> Matrix2D? in
            if case .pushTransform(let m) = cmd { return m }
            return nil
        }
        let pushTransformsShifted = cmdsShifted.compactMap { cmd -> Matrix2D? in
            if case .pushTransform(let m) = cmd { return m }
            return nil
        }

        XCTAssertNotEqual(pushTransformsIdentity, pushTransformsShifted,
            "UserTransform should produce different pushTransform matrices")
    }

    func testRender_withoutInputGeometry_noInputClipGenerated() throws {
        // Given: no mediaInput layer → standard render path
        let json = """
        {
          "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
          "assets": [{ "id": "image_0", "w": 540, "h": 960, "u": "images/", "p": "img.png", "e": 0 }],
          "layers": [
            { "ty": 2, "ind": 1, "nm": "media", "refId": "image_0",
              "ks": { "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
                      "p": { "a": 0, "k": [270,480,0] }, "a": { "a": 0, "k": [270,480,0] },
                      "s": { "a": 0, "k": [100,100,100] } },
              "ip": 0, "op": 300, "st": 0
            }
          ]
        }
        """
        let lottie = try decodeLottie(json)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])

        // When
        var ir = try compiler.compile(
            lottie: lottie,
            animRef: "test",
            bindingKey: "media",
            assetIndex: assetIndex,
            pathRegistry: &_testRegistry
        )
        let commands = ir.renderCommands(frameIndex: 0)

        // Then: no beginMask (no inputClip, no masks)
        let beginMaskCount = commands.filter {
            if case .beginMask = $0 { return true }
            return false
        }.count
        XCTAssertEqual(beginMaskCount, 0, "Without inputGeometry, no masks should be generated")
    }

    // MARK: - Hit-Test API

    func testMediaInputPath_returnsPathInCompSpace() throws {
        // Given: mediaInput with identity transform → path should be returned as-is
        let json = lottieWithMediaInput(mediaInRoot: true)
        let lottie = try decodeLottie(json)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])

        // When
        var ir = try compiler.compile(
            lottie: lottie,
            animRef: "test",
            bindingKey: "media",
            assetIndex: assetIndex,
            pathRegistry: &_testRegistry
        )
        let path = ir.mediaInputPath(frame: 0)

        // Then
        XCTAssertNotNil(path, "mediaInputPath should return a path when mediaInput exists")
        XCTAssertEqual(path?.vertices.count, 4, "Rectangle path should have 4 vertices")
        XCTAssertTrue(path?.closed ?? false, "Path should be closed")
    }

    func testMediaInputPath_noMediaInput_returnsNil() throws {
        // Given: no mediaInput
        let json = """
        {
          "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
          "assets": [{ "id": "image_0", "w": 540, "h": 960, "u": "images/", "p": "img.png", "e": 0 }],
          "layers": [
            { "ty": 2, "ind": 1, "nm": "media", "refId": "image_0",
              "ks": { "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
                      "p": { "a": 0, "k": [0,0,0] }, "a": { "a": 0, "k": [0,0,0] },
                      "s": { "a": 0, "k": [100,100,100] } },
              "ip": 0, "op": 300, "st": 0
            }
          ]
        }
        """
        let lottie = try decodeLottie(json)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])

        // When
        var ir = try compiler.compile(
            lottie: lottie,
            animRef: "test",
            bindingKey: "media",
            assetIndex: assetIndex,
            pathRegistry: &_testRegistry
        )
        let path = ir.mediaInputPath(frame: 0)

        // Then
        XCTAssertNil(path)
    }

    func testMediaInputPath_appliesGroupTransforms() throws {
        // Given: mediaInput layer with identity layer transform BUT non-identity groupTransform.
        // The old code had an early return on `worldMatrix == .identity` that would skip
        // groupTransforms entirely — this test guards against that regression.
        let groupTransformJSON = """
        , { "ty": "tr",
            "p": { "a": 0, "k": [100, 200] },
            "a": { "a": 0, "k": [0, 0] },
            "s": { "a": 0, "k": [100, 100] },
            "r": { "a": 0, "k": 0 },
            "o": { "a": 0, "k": 100 } }
        """
        let json = lottieWithMediaInput(
            mediaInputLayer: mediaInputLayerJSON(extraShapes: groupTransformJSON),
            mediaInRoot: true
        )
        let lottie = try decodeLottie(json)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])

        // When
        var ir = try compiler.compile(
            lottie: lottie,
            animRef: "test",
            bindingKey: "media",
            assetIndex: assetIndex,
            pathRegistry: &_testRegistry
        )
        let path = ir.mediaInputPath(frame: 0)

        // Then: basePath has vertices [[0,0],[100,0],[100,100],[0,100]].
        // groupTransform translates by (100, 200), so every vertex shifts by that amount.
        XCTAssertNotNil(path)
        let verts = path!.vertices
        XCTAssertEqual(verts.count, 4)
        XCTAssertEqual(verts[0].x, 100, accuracy: 0.01)
        XCTAssertEqual(verts[0].y, 200, accuracy: 0.01)
        XCTAssertEqual(verts[1].x, 200, accuracy: 0.01)
        XCTAssertEqual(verts[1].y, 200, accuracy: 0.01)
        XCTAssertEqual(verts[2].x, 200, accuracy: 0.01)
        XCTAssertEqual(verts[2].y, 300, accuracy: 0.01)
        XCTAssertEqual(verts[3].x, 100, accuracy: 0.01)
        XCTAssertEqual(verts[3].y, 300, accuracy: 0.01)

        // Also verify mediaInputWorldMatrix includes groupTransforms
        let matrix = ir.mediaInputWorldMatrix(frame: 0)
        XCTAssertNotNil(matrix)
        XCTAssertNotEqual(matrix, .identity,
            "Composed matrix must include groupTransform even when layer transform is identity")
    }

    func testMediaInputPath_accountsForPrecompContainerTransform() throws {
        // Given: mediaInput inside a precomp; precomp container translates by (540, 0).
        // mediaInputPath must include the precomp chain transform so the path
        // ends up in root composition space, not precomp-local space.
        let json = """
        {
          "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
          "assets": [
            { "id": "image_0", "w": 540, "h": 960, "u": "images/", "p": "img.png", "e": 0 },
            {
              "id": "comp_0", "nm": "precomp", "fr": 30,
              "layers": [
                {
                  "ty": 4, "ind": 1, "nm": "mediaInput", "hd": true,
                  "shapes": [
                    { "ty": "gr", "it": [
                      { "ty": "sh", "ks": { "a": 0, "k": {
                        "v": [[0,0],[100,0],[100,100],[0,100]],
                        "i": [[0,0],[0,0],[0,0],[0,0]],
                        "o": [[0,0],[0,0],[0,0],[0,0]],
                        "c": true
                      }}},
                      { "ty": "fl", "c": { "a": 0, "k": [0,0,0,1] }, "o": { "a": 0, "k": 100 } }
                    ]}
                  ],
                  "ks": {
                    "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
                    "p": { "a": 0, "k": [0,0,0] }, "a": { "a": 0, "k": [0,0,0] },
                    "s": { "a": 0, "k": [100,100,100] }
                  },
                  "ip": 0, "op": 300, "st": 0
                },
                {
                  "ty": 2, "ind": 2, "nm": "media", "refId": "image_0",
                  "ks": {
                    "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
                    "p": { "a": 0, "k": [270,480,0] }, "a": { "a": 0, "k": [270,480,0] },
                    "s": { "a": 0, "k": [100,100,100] }
                  },
                  "ip": 0, "op": 300, "st": 0
                }
              ]
            }
          ],
          "layers": [
            {
              "ty": 0, "ind": 1, "nm": "precomp_layer", "refId": "comp_0",
              "ks": {
                "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
                "p": { "a": 0, "k": [540, 0, 0] },
                "a": { "a": 0, "k": [0, 0, 0] },
                "s": { "a": 0, "k": [100, 100, 100] }
              },
              "w": 1080, "h": 1920,
              "ip": 0, "op": 300, "st": 0
            }
          ]
        }
        """
        let lottie = try decodeLottie(json)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])

        var ir = try compiler.compile(
            lottie: lottie,
            animRef: "test",
            bindingKey: "media",
            assetIndex: assetIndex,
            pathRegistry: &_testRegistry
        )

        // When
        let path = ir.mediaInputPath(frame: 0)

        // Then: precomp container T(540, 0) + identity layer + identity groupTransform
        // basePath [[0,0],[100,0],[100,100],[0,100]] → shifted by (540, 0)
        XCTAssertNotNil(path)
        let verts = path!.vertices
        XCTAssertEqual(verts.count, 4)
        XCTAssertEqual(verts[0].x, 540, accuracy: 0.01)
        XCTAssertEqual(verts[0].y, 0, accuracy: 0.01)
        XCTAssertEqual(verts[1].x, 640, accuracy: 0.01)
        XCTAssertEqual(verts[1].y, 0, accuracy: 0.01)
        XCTAssertEqual(verts[2].x, 640, accuracy: 0.01)
        XCTAssertEqual(verts[2].y, 100, accuracy: 0.01)
        XCTAssertEqual(verts[3].x, 540, accuracy: 0.01)
        XCTAssertEqual(verts[3].y, 100, accuracy: 0.01)

        // mediaInputWorldMatrix must also include the precomp chain
        let matrix = ir.mediaInputWorldMatrix(frame: 0)
        XCTAssertNotNil(matrix)
        XCTAssertNotEqual(matrix, .identity,
            "Composed matrix must include precomp container transform")
    }

    func testMediaInputPath_precompChainPlusGroupTransforms() throws {
        // Given: precomp container T(540, 0) + groupTransform T(50, 100).
        // Both must be included: composed = T(540,0) * T(50,100) = T(590, 100).
        let json = """
        {
          "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
          "assets": [
            { "id": "image_0", "w": 540, "h": 960, "u": "images/", "p": "img.png", "e": 0 },
            {
              "id": "comp_0", "nm": "precomp", "fr": 30,
              "layers": [
                {
                  "ty": 4, "ind": 1, "nm": "mediaInput", "hd": true,
                  "shapes": [
                    { "ty": "gr", "it": [
                      { "ty": "sh", "ks": { "a": 0, "k": {
                        "v": [[0,0],[100,0],[100,100],[0,100]],
                        "i": [[0,0],[0,0],[0,0],[0,0]],
                        "o": [[0,0],[0,0],[0,0],[0,0]],
                        "c": true
                      }}},
                      { "ty": "fl", "c": { "a": 0, "k": [0,0,0,1] }, "o": { "a": 0, "k": 100 } },
                      { "ty": "tr",
                        "p": { "a": 0, "k": [50, 100] },
                        "a": { "a": 0, "k": [0, 0] },
                        "s": { "a": 0, "k": [100, 100] },
                        "r": { "a": 0, "k": 0 },
                        "o": { "a": 0, "k": 100 } }
                    ]}
                  ],
                  "ks": {
                    "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
                    "p": { "a": 0, "k": [0,0,0] }, "a": { "a": 0, "k": [0,0,0] },
                    "s": { "a": 0, "k": [100,100,100] }
                  },
                  "ip": 0, "op": 300, "st": 0
                },
                {
                  "ty": 2, "ind": 2, "nm": "media", "refId": "image_0",
                  "ks": {
                    "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
                    "p": { "a": 0, "k": [270,480,0] }, "a": { "a": 0, "k": [270,480,0] },
                    "s": { "a": 0, "k": [100,100,100] }
                  },
                  "ip": 0, "op": 300, "st": 0
                }
              ]
            }
          ],
          "layers": [
            {
              "ty": 0, "ind": 1, "nm": "precomp_layer", "refId": "comp_0",
              "ks": {
                "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
                "p": { "a": 0, "k": [540, 0, 0] },
                "a": { "a": 0, "k": [0, 0, 0] },
                "s": { "a": 0, "k": [100, 100, 100] }
              },
              "w": 1080, "h": 1920,
              "ip": 0, "op": 300, "st": 0
            }
          ]
        }
        """
        let lottie = try decodeLottie(json)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])

        var ir = try compiler.compile(
            lottie: lottie,
            animRef: "test",
            bindingKey: "media",
            assetIndex: assetIndex,
            pathRegistry: &_testRegistry
        )

        // When
        let path = ir.mediaInputPath(frame: 0)

        // Then: T(540,0) from precomp chain + T(50,100) from groupTransform = T(590,100)
        // basePath [[0,0],[100,0],[100,100],[0,100]] → shifted by (590, 100)
        XCTAssertNotNil(path)
        let verts = path!.vertices
        XCTAssertEqual(verts.count, 4)
        XCTAssertEqual(verts[0].x, 590, accuracy: 0.01)
        XCTAssertEqual(verts[0].y, 100, accuracy: 0.01)
        XCTAssertEqual(verts[1].x, 690, accuracy: 0.01)
        XCTAssertEqual(verts[1].y, 100, accuracy: 0.01)
        XCTAssertEqual(verts[2].x, 690, accuracy: 0.01)
        XCTAssertEqual(verts[2].y, 200, accuracy: 0.01)
        XCTAssertEqual(verts[3].x, 590, accuracy: 0.01)
        XCTAssertEqual(verts[3].y, 200, accuracy: 0.01)
    }

    func testMediaInputWorldMatrix_returnsIdentityForUntransformed() throws {
        // Given: mediaInput at origin with identity transform
        let json = lottieWithMediaInput(mediaInRoot: true)
        let lottie = try decodeLottie(json)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])

        // When
        var ir = try compiler.compile(
            lottie: lottie,
            animRef: "test",
            bindingKey: "media",
            assetIndex: assetIndex,
            pathRegistry: &_testRegistry
        )
        let matrix = ir.mediaInputWorldMatrix(frame: 0)

        // Then: mediaInput has p=[0,0,0], a=[0,0,0], s=[100,100,100], r=0
        // This should produce an identity matrix
        XCTAssertNotNil(matrix)
        XCTAssertEqual(matrix, .identity, "Untransformed mediaInput should have identity world matrix")
    }

    func testMediaInputWorldMatrix_noMediaInput_returnsNil() throws {
        // Given: no mediaInput
        let json = """
        {
          "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
          "assets": [{ "id": "image_0", "w": 540, "h": 960, "u": "images/", "p": "img.png", "e": 0 }],
          "layers": [
            { "ty": 2, "ind": 1, "nm": "media", "refId": "image_0",
              "ks": { "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
                      "p": { "a": 0, "k": [0,0,0] }, "a": { "a": 0, "k": [0,0,0] },
                      "s": { "a": 0, "k": [100,100,100] } },
              "ip": 0, "op": 300, "st": 0
            }
          ]
        }
        """
        let lottie = try decodeLottie(json)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])

        var ir = try compiler.compile(
            lottie: lottie,
            animRef: "test",
            bindingKey: "media",
            assetIndex: assetIndex,
            pathRegistry: &_testRegistry
        )

        XCTAssertNil(ir.mediaInputWorldMatrix(frame: 0))
    }

    // MARK: - Render: InputClip with Matte Combination

    func testRender_matteAndInputClip_bothPresent() throws {
        // Given: matte source (td=1) + matte consumer (tt=1, media) with mediaInput
        // matte_source(td=1) → media(tt=1) + mediaInput(hd=true) all in root
        let json = """
        {
          "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
          "assets": [{ "id": "image_0", "w": 540, "h": 960, "u": "images/", "p": "img.png", "e": 0 }],
          "layers": [
            {
              "ty": 4, "ind": 10, "nm": "mediaInput", "hd": true,
              "shapes": [
                { "ty": "gr", "it": [
                  { "ty": "sh", "ks": { "a": 0, "k": {
                    "v": [[0,0],[200,0],[200,200],[0,200]],
                    "i": [[0,0],[0,0],[0,0],[0,0]],
                    "o": [[0,0],[0,0],[0,0],[0,0]],
                    "c": true
                  }}},
                  { "ty": "fl", "c": { "a": 0, "k": [0,0,0,1] }, "o": { "a": 0, "k": 100 } }
                ]}
              ],
              "ks": { "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
                      "p": { "a": 0, "k": [0,0,0] }, "a": { "a": 0, "k": [0,0,0] },
                      "s": { "a": 0, "k": [100,100,100] } },
              "ip": 0, "op": 300, "st": 0
            },
            {
              "ty": 4, "ind": 2, "nm": "matte_source", "td": 1,
              "shapes": [
                { "ty": "gr", "it": [
                  { "ty": "sh", "ks": { "a": 0, "k": {
                    "v": [[0,0],[500,0],[500,500],[0,500]],
                    "i": [[0,0],[0,0],[0,0],[0,0]],
                    "o": [[0,0],[0,0],[0,0],[0,0]],
                    "c": true
                  }}},
                  { "ty": "fl", "c": { "a": 0, "k": [1,1,1,1] }, "o": { "a": 0, "k": 100 } }
                ]}
              ],
              "ks": { "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
                      "p": { "a": 0, "k": [0,0,0] }, "a": { "a": 0, "k": [0,0,0] },
                      "s": { "a": 0, "k": [100,100,100] } },
              "ip": 0, "op": 300, "st": 0
            },
            {
              "ty": 2, "ind": 3, "nm": "media", "refId": "image_0", "tt": 1,
              "ks": { "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
                      "p": { "a": 0, "k": [270,480,0] }, "a": { "a": 0, "k": [270,480,0] },
                      "s": { "a": 0, "k": [100,100,100] } },
              "ip": 0, "op": 300, "st": 0
            }
          ]
        }
        """
        let lottie = try decodeLottie(json)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])

        // When
        var ir = try compiler.compile(
            lottie: lottie,
            animRef: "test",
            bindingKey: "media",
            assetIndex: assetIndex,
            pathRegistry: &_testRegistry
        )
        let commands = ir.renderCommands(frameIndex: 0)

        // Then: should have both matte and inputClip structures
        let hasBeginMatte = commands.contains {
            if case .beginMatte = $0 { return true }
            return false
        }
        let hasEndMatte = commands.contains {
            if case .endMatte = $0 { return true }
            return false
        }
        XCTAssertTrue(hasBeginMatte, "Should have beginMatte for matte consumer")
        XCTAssertTrue(hasEndMatte, "Should have endMatte")

        // inputClip mask should be present (intersect mode)
        let hasIntersectMask = commands.contains {
            if case .beginMask(let mode, _, _, _, _) = $0 { return mode == .intersect }
            return false
        }
        XCTAssertTrue(hasIntersectMask, "Should have beginMask(.intersect) for inputClip")

        // drawImage for media layer should still be present
        let drawImageCount = commands.filter {
            if case .drawImage = $0 { return true }
            return false
        }.count
        XCTAssertEqual(drawImageCount, 1, "Should render one image (binding layer)")
    }

    // MARK: - Determinism

    func testCompile_withMediaInput_deterministic() throws {
        // Given
        let json = lottieWithMediaInput()
        let lottie = try decodeLottie(json)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])

        // When: compile twice with separate registries so PathIDs match
        var reg1 = PathRegistry()
        let ir1 = try compiler.compile(
            lottie: lottie,
            animRef: "test",
            bindingKey: "media",
            assetIndex: assetIndex,
            pathRegistry: &reg1
        )
        var reg2 = PathRegistry()
        let ir2 = try compiler.compile(
            lottie: lottie,
            animRef: "test",
            bindingKey: "media",
            assetIndex: assetIndex,
            pathRegistry: &reg2
        )

        // Then
        XCTAssertEqual(ir1.inputGeometry, ir2.inputGeometry,
            "InputGeometry should be deterministic across compilations")
        XCTAssertEqual(ir1.meta, ir2.meta)
        XCTAssertEqual(ir1.binding, ir2.binding)
    }

    // MARK: - LottieLayer hidden decoding

    func testLottieLayer_hdTrue_decodedCorrectly() throws {
        let json = """
        {
          "ty": 4, "ind": 1, "nm": "test_layer", "hd": true,
          "shapes": [],
          "ks": { "o": { "a": 0, "k": 100 } },
          "ip": 0, "op": 300
        }
        """
        let layer = try JSONDecoder().decode(LottieLayer.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(layer.hidden, true)
    }

    func testLottieLayer_hdFalse_decodedCorrectly() throws {
        let json = """
        {
          "ty": 4, "ind": 1, "nm": "test_layer", "hd": false,
          "shapes": [],
          "ks": { "o": { "a": 0, "k": 100 } },
          "ip": 0, "op": 300
        }
        """
        let layer = try JSONDecoder().decode(LottieLayer.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(layer.hidden, false)
    }

    func testLottieLayer_hdMissing_decodedAsNil() throws {
        let json = """
        {
          "ty": 4, "ind": 1, "nm": "test_layer",
          "shapes": [],
          "ks": { "o": { "a": 0, "k": 100 } },
          "ip": 0, "op": 300
        }
        """
        let layer = try JSONDecoder().decode(LottieLayer.self, from: json.data(using: .utf8)!)
        XCTAssertNil(layer.hidden)
    }

    // MARK: - Render Commands: Balanced Groups/Transforms

    func testRender_withInputClip_balancedGroupsAndTransforms() throws {
        let json = lottieWithMediaInput()
        let lottie = try decodeLottie(json)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])

        var ir = try compiler.compile(
            lottie: lottie,
            animRef: "test",
            bindingKey: "media",
            assetIndex: assetIndex,
            pathRegistry: &_testRegistry
        )
        let commands = ir.renderCommands(frameIndex: 0)

        // Verify balanced begin/end groups
        let beginGroupCount = commands.filter {
            if case .beginGroup = $0 { return true }
            return false
        }.count
        let endGroupCount = commands.filter {
            if case .endGroup = $0 { return true }
            return false
        }.count
        XCTAssertEqual(beginGroupCount, endGroupCount,
            "beginGroup (\(beginGroupCount)) and endGroup (\(endGroupCount)) must match")

        // Verify balanced push/pop transforms
        let pushCount = commands.filter {
            if case .pushTransform = $0 { return true }
            return false
        }.count
        let popCount = commands.filter {
            if case .popTransform = $0 { return true }
            return false
        }.count
        XCTAssertEqual(pushCount, popCount,
            "pushTransform (\(pushCount)) and popTransform (\(popCount)) must match")
    }

    // MARK: - Binding Layer Masks Ignored (Hardening)

    /// Binding layer in root with masksProperties + mediaInput (→ inputClip path).
    /// masksProperties must be SKIPPED, only beginMask(.intersect) from inputClip allowed.
    private static let bindingWithMasksAndMediaInputJSON = """
    {
      "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
      "assets": [{ "id": "image_0", "w": 540, "h": 960, "u": "images/", "p": "img.png", "e": 0 }],
      "layers": [
        {
          "ty": 4, "ind": 10, "nm": "mediaInput", "hd": true,
          "shapes": [{ "ty": "gr", "it": [
            { "ty": "sh", "ks": { "a": 0, "k": {
              "v": [[0,0],[540,0],[540,960],[0,960]],
              "i": [[0,0],[0,0],[0,0],[0,0]],
              "o": [[0,0],[0,0],[0,0],[0,0]],
              "c": true
            }}},
            { "ty": "fl", "c": { "a": 0, "k": [0,0,0,1] }, "o": { "a": 0, "k": 100 } }
          ]}],
          "ks": { "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
                  "p": { "a": 0, "k": [0,0,0] }, "a": { "a": 0, "k": [0,0,0] },
                  "s": { "a": 0, "k": [100,100,100] } },
          "ip": 0, "op": 300, "st": 0
        },
        {
          "ty": 2, "ind": 1, "nm": "media", "refId": "image_0",
          "hasMask": true,
          "masksProperties": [{
            "inv": false, "mode": "a",
            "pt": { "a": 0, "k": {
              "v": [[10,10],[500,10],[500,900],[10,900]],
              "i": [[0,0],[0,0],[0,0],[0,0]],
              "o": [[0,0],[0,0],[0,0],[0,0]],
              "c": true
            }},
            "o": { "a": 0, "k": 100 }
          }],
          "ks": { "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
                  "p": { "a": 0, "k": [270,480,0] }, "a": { "a": 0, "k": [270,480,0] },
                  "s": { "a": 0, "k": [100,100,100] } },
          "ip": 0, "op": 300, "st": 0
        }
      ]
    }
    """

    /// Binding layer in root with masksProperties but NO mediaInput (→ standard path).
    private static let bindingWithMasksNoMediaInputJSON = """
    {
      "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
      "assets": [{ "id": "image_0", "w": 540, "h": 960, "u": "images/", "p": "img.png", "e": 0 }],
      "layers": [
        {
          "ty": 2, "ind": 1, "nm": "media", "refId": "image_0",
          "hasMask": true,
          "masksProperties": [{
            "inv": false, "mode": "a",
            "pt": { "a": 0, "k": {
              "v": [[10,10],[500,10],[500,900],[10,900]],
              "i": [[0,0],[0,0],[0,0],[0,0]],
              "o": [[0,0],[0,0],[0,0],[0,0]],
              "c": true
            }},
            "o": { "a": 0, "k": 100 }
          }],
          "ks": { "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
                  "p": { "a": 0, "k": [270,480,0] }, "a": { "a": 0, "k": [270,480,0] },
                  "s": { "a": 0, "k": [100,100,100] } },
          "ip": 0, "op": 300, "st": 0
        }
      ]
    }
    """

    func testBindingLayerMasksIgnored_inputClipPath_noAddMask() throws {
        // Given: binding layer with masksProperties + mediaInput (inputClip path)
        let lottie = try decodeLottie(Self.bindingWithMasksAndMediaInputJSON)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])

        var ir = try compiler.compile(
            lottie: lottie,
            animRef: "test",
            bindingKey: "media",
            assetIndex: assetIndex,
            pathRegistry: &_testRegistry
        )

        // When: render with non-identity userTransform (the bug scenario)
        let userShift = Matrix2D.translation(x: 50, y: -30)
        let (commands, issues) = ir.renderCommandsWithIssues(
            frameIndex: 0,
            userTransform: userShift
        )

        // Then: only beginMask(.intersect) from inputClip — NO beginMask(.add) from masksProperties
        let addMasks = commands.filter {
            if case .beginMask(let mode, _, _, _, _) = $0 { return mode == .add }
            return false
        }
        XCTAssertEqual(addMasks.count, 0,
            "Binding layer masksProperties must be SKIPPED (inputClip path). Found \(addMasks.count) add masks.")

        let intersectMasks = commands.filter {
            if case .beginMask(let mode, _, _, _, _) = $0 { return mode == .intersect }
            return false
        }
        XCTAssertEqual(intersectMasks.count, 1,
            "Should have exactly 1 inputClip intersect mask, got \(intersectMasks.count)")

        // Warning must be emitted
        let maskWarnings = issues.filter { $0.code == RenderIssue.codeBindingLayerMasksIgnored }
        XCTAssertEqual(maskWarnings.count, 1,
            "Should emit exactly 1 BINDING_LAYER_MASKS_IGNORED warning")
        XCTAssertEqual(maskWarnings.first?.severity, .warning)

        // Commands must be balanced
        XCTAssertTrue(commands.isBalanced(), "Commands must be balanced after skipping masks")
        let errors = RenderCommandValidator.validateScopeBalance(commands)
        XCTAssertTrue(errors.isEmpty, "Scope balance errors: \(errors)")
    }

    func testBindingLayerMasksIgnored_standardPath_noMaskEmitted() throws {
        // Given: binding layer with masksProperties but NO mediaInput (standard path)
        let lottie = try decodeLottie(Self.bindingWithMasksNoMediaInputJSON)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])

        var ir = try compiler.compile(
            lottie: lottie,
            animRef: "test",
            bindingKey: "media",
            assetIndex: assetIndex,
            pathRegistry: &_testRegistry
        )

        // When: render with non-identity userTransform
        let userShift = Matrix2D.translation(x: 50, y: -30)
        let (commands, issues) = ir.renderCommandsWithIssues(
            frameIndex: 0,
            userTransform: userShift
        )

        // Then: NO beginMask at all (no inputClip, no masksProperties)
        let allMasks = commands.filter {
            if case .beginMask = $0 { return true }
            return false
        }
        XCTAssertEqual(allMasks.count, 0,
            "Standard path: binding layer masksProperties must be SKIPPED. Found \(allMasks.count) masks.")

        // Warning must be emitted
        let maskWarnings = issues.filter { $0.code == RenderIssue.codeBindingLayerMasksIgnored }
        XCTAssertEqual(maskWarnings.count, 1,
            "Should emit BINDING_LAYER_MASKS_IGNORED warning even on standard path")

        // Commands must be balanced
        XCTAssertTrue(commands.isBalanced())
    }

    func testBindingLayerMasksIgnored_userTransformDoesNotShrinkVisibleArea() throws {
        // Regression: with the old code, userTransform ≠ identity would cause
        // masksProperties to shift with the photo (inside pushTransform(mediaWorldWithUser)),
        // creating a smaller intersection with the fixed inputClip — "crop" vs "clip".
        // After the fix, changing userTransform must NOT change the number of mask commands.
        let lottie = try decodeLottie(Self.bindingWithMasksAndMediaInputJSON)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])

        var ir = try compiler.compile(
            lottie: lottie,
            animRef: "test",
            bindingKey: "media",
            assetIndex: assetIndex,
            pathRegistry: &_testRegistry
        )

        let cmdsIdentity = ir.renderCommands(frameIndex: 0, userTransform: .identity)
        let cmdsShifted = ir.renderCommands(
            frameIndex: 0,
            userTransform: Matrix2D.translation(x: 200, y: -150)
        )

        // Mask count must be identical regardless of userTransform
        let maskCountIdentity = cmdsIdentity.filter {
            if case .beginMask = $0 { return true }; return false
        }.count
        let maskCountShifted = cmdsShifted.filter {
            if case .beginMask = $0 { return true }; return false
        }.count

        XCTAssertEqual(maskCountIdentity, maskCountShifted,
            "Mask count must not change with userTransform (identity: \(maskCountIdentity), shifted: \(maskCountShifted))")
        XCTAssertEqual(maskCountIdentity, 1, "Only inputClip intersect mask expected")
    }

    func testNonBindingLayerMasks_stillEmitted() throws {
        // Non-binding layers with masksProperties must still emit masks normally.
        // This ensures the hardening doesn't over-suppress.
        let json = """
        {
          "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
          "assets": [{ "id": "image_0", "w": 540, "h": 960, "u": "images/", "p": "img.png", "e": 0 }],
          "layers": [
            {
              "ty": 2, "ind": 1, "nm": "decoration", "refId": "image_0",
              "hasMask": true,
              "masksProperties": [{
                "inv": false, "mode": "a",
                "pt": { "a": 0, "k": {
                  "v": [[0,0],[540,0],[540,960],[0,960]],
                  "i": [[0,0],[0,0],[0,0],[0,0]],
                  "o": [[0,0],[0,0],[0,0],[0,0]],
                  "c": true
                }},
                "o": { "a": 0, "k": 100 }
              }],
              "ks": { "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
                      "p": { "a": 0, "k": [270,480,0] }, "a": { "a": 0, "k": [270,480,0] },
                      "s": { "a": 0, "k": [100,100,100] } },
              "ip": 0, "op": 300, "st": 0
            },
            {
              "ty": 2, "ind": 99, "nm": "media", "refId": "image_0",
              "ks": { "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
                      "p": { "a": 0, "k": [0,0,0] }, "a": { "a": 0, "k": [0,0,0] },
                      "s": { "a": 0, "k": [100,100,100] } },
              "ip": 0, "op": 300, "st": 0
            }
          ]
        }
        """
        let lottie = try decodeLottie(json)
        let assetIndex = AssetIndex(byId: ["image_0": "images/img.png"])

        // Compile with bindingKey "media" — layer "decoration" is NOT the binding layer
        let ir = try compiler.compile(
            lottie: lottie,
            animRef: "test",
            bindingKey: "media",
            assetIndex: assetIndex,
            pathRegistry: &_testRegistry
        )
        let (commands, issues) = ir.renderCommandsWithIssues(frameIndex: 0)

        // Non-binding layer masks MUST be emitted
        let addMasks = commands.filter {
            if case .beginMask(let mode, _, _, _, _) = $0 { return mode == .add }
            return false
        }
        XCTAssertEqual(addMasks.count, 1,
            "Non-binding layer masks must be emitted normally")

        // No BINDING_LAYER_MASKS_IGNORED warning
        let maskWarnings = issues.filter { $0.code == RenderIssue.codeBindingLayerMasksIgnored }
        XCTAssertTrue(maskWarnings.isEmpty,
            "Non-binding layer should not produce BINDING_LAYER_MASKS_IGNORED warning")

        XCTAssertTrue(commands.isBalanced())
    }
}

// MARK: - Validator: MediaInput Tests

final class MediaInputValidatorTests: XCTestCase {
    private var validator: AnimValidator!
    private var loader: AnimLoader!
    private var packageLoader: ScenePackageLoader!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        validator = AnimValidator()
        loader = AnimLoader()
        packageLoader = ScenePackageLoader()
    }

    override func tearDown() {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        validator = nil
        loader = nil
        packageLoader = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func createTempPackage(
        sceneJSON: String,
        animFiles: [String: String],
        images: [String] = []
    ) throws -> ScenePackage {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let sceneURL = tempDir.appendingPathComponent("scene.json")
        try sceneJSON.write(to: sceneURL, atomically: true, encoding: .utf8)

        for (name, content) in animFiles {
            let url = tempDir.appendingPathComponent(name)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }

        if !images.isEmpty {
            let imagesDir = tempDir.appendingPathComponent("images")
            try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
            for imageName in images {
                let imageURL = imagesDir.appendingPathComponent(imageName)
                try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)
            }
        }

        return try packageLoader.load(from: tempDir)
    }

    private func sceneJSON() -> String {
        """
        {
          "schemaVersion": "0.1",
          "canvas": { "width": 1080, "height": 1920, "fps": 30, "durationFrames": 300 },
          "mediaBlocks": [{
            "blockId": "block_01",
            "zIndex": 0,
            "rect": { "x": 0, "y": 0, "width": 1080, "height": 1920 },
            "containerClip": "slotRect",
            "input": {
              "rect": { "x": 0, "y": 0, "width": 1080, "height": 1920 },
              "bindingKey": "media",
              "allowedMedia": ["photo"]
            },
            "variants": [{ "variantId": "v1", "animRef": "anim.json" }]
          }]
        }
        """
    }

    private func validateAnim(_ animJSON: String, images: [String] = ["img.png"]) throws -> ValidationReport {
        let package = try createTempPackage(
            sceneJSON: sceneJSON(),
            animFiles: ["anim.json": animJSON],
            images: images
        )
        let loaded = try loader.loadAnimations(from: package)
        return validator.validate(scene: package.scene, package: package, loaded: loaded)
    }

    private static let rectPathJSON = """
    { "a": 0, "k": {
        "v": [[0,0],[100,0],[100,100],[0,100]],
        "i": [[0,0],[0,0],[0,0],[0,0]],
        "o": [[0,0],[0,0],[0,0],[0,0]],
        "c": true
    }}
    """

    /// Builds a valid Lottie JSON with mediaInput in a precomp alongside the binding layer
    private func animWithMediaInput(
        mediaInputType: Int = 4,
        mediaInputShapes: String = """
        { "ty": "gr", "it": [
          { "ty": "sh", "ks": \(rectPathJSON) },
          { "ty": "fl", "c": { "a": 0, "k": [0,0,0,1] }, "o": { "a": 0, "k": 100 } }
        ]}
        """,
        mediaInputHidden: Bool = true,
        mediaInputInRoot: Bool = false,
        mediaInRoot: Bool = false,
        extraMediaInputShapes: String = ""
    ) -> String {
        let hdPart = mediaInputHidden ? "\"hd\": true," : ""
        let shapesArray = extraMediaInputShapes.isEmpty
            ? "[\(mediaInputShapes)]"
            : "[\(mediaInputShapes), \(extraMediaInputShapes)]"

        let mediaInputLayer = """
        {
          "ty": \(mediaInputType), "ind": 10, "nm": "mediaInput",
          \(hdPart)
          "shapes": \(shapesArray),
          "ks": { "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
                  "p": { "a": 0, "k": [0,0,0] }, "a": { "a": 0, "k": [0,0,0] },
                  "s": { "a": 0, "k": [100,100,100] } },
          "ip": 0, "op": 300, "st": 0
        }
        """

        let mediaLayer = """
        {
          "ty": 2, "ind": 1, "nm": "media", "refId": "image_0",
          "ks": { "o": { "a": 0, "k": 100 }, "r": { "a": 0, "k": 0 },
                  "p": { "a": 0, "k": [270,480,0] }, "a": { "a": 0, "k": [270,480,0] },
                  "s": { "a": 0, "k": [100,100,100] } },
          "ip": 0, "op": 300, "st": 0
        }
        """

        if mediaInRoot {
            return """
            {
              "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
              "assets": [{ "id": "image_0", "w": 540, "h": 960, "u": "images/", "p": "img.png", "e": 0 }],
              "layers": [\(mediaInputLayer), \(mediaLayer)]
            }
            """
        }

        if mediaInputInRoot {
            // mediaInput in root, media in precomp (different comp → should fail same-comp)
            return """
            {
              "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
              "assets": [
                { "id": "image_0", "w": 540, "h": 960, "u": "images/", "p": "img.png", "e": 0 },
                { "id": "comp_0", "nm": "precomp", "fr": 30,
                  "layers": [\(mediaLayer)]
                }
              ],
              "layers": [
                \(mediaInputLayer),
                { "ty": 0, "ind": 1, "nm": "precomp_layer", "refId": "comp_0",
                  "ks": { "o": { "a": 0, "k": 100 } },
                  "w": 1080, "h": 1920, "ip": 0, "op": 300, "st": 0
                }
              ]
            }
            """
        }

        // Both in same precomp (default)
        return """
        {
          "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
          "assets": [
            { "id": "image_0", "w": 540, "h": 960, "u": "images/", "p": "img.png", "e": 0 },
            { "id": "comp_0", "nm": "precomp", "fr": 30,
              "layers": [\(mediaInputLayer), \(mediaLayer)]
            }
          ],
          "layers": [
            { "ty": 0, "ind": 1, "nm": "precomp_layer", "refId": "comp_0",
              "ks": { "o": { "a": 0, "k": 100 } },
              "w": 1080, "h": 1920, "ip": 0, "op": 300, "st": 0
            }
          ]
        }
        """
    }

    // MARK: - Valid mediaInput

    func testValidate_validMediaInput_noErrors() throws {
        let anim = animWithMediaInput()
        let report = try validateAnim(anim)

        let mediaInputErrors = report.errors.filter {
            $0.code.hasPrefix("MEDIA_INPUT")
        }
        XCTAssertEqual(mediaInputErrors.count, 0,
            "Valid mediaInput should produce no MEDIA_INPUT errors, got: \(mediaInputErrors.map { $0.code })")
    }

    // MARK: - MEDIA_INPUT_MISSING

    func testValidate_noMediaInput_returnsMissingError() throws {
        // No mediaInput layer at all
        let anim = """
        {
          "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
          "assets": [{ "id": "image_0", "w": 540, "h": 960, "u": "images/", "p": "img.png", "e": 0 }],
          "layers": [
            { "ty": 2, "ind": 1, "nm": "media", "refId": "image_0",
              "ks": { "o": { "a": 0, "k": 100 } },
              "ip": 0, "op": 300, "st": 0
            }
          ]
        }
        """
        let report = try validateAnim(anim)

        let missing = report.warnings.first { $0.code == AnimValidationCode.mediaInputMissing }
        XCTAssertNotNil(missing, "Should report MEDIA_INPUT_MISSING when no mediaInput layer exists")
    }

    // MARK: - MEDIA_INPUT_NOT_SHAPE

    func testValidate_mediaInputNotShape_returnsNotShapeError() throws {
        // mediaInput is ty=3 (null) instead of ty=4 (shape)
        let anim = """
        {
          "fr": 30, "ip": 0, "op": 300, "w": 1080, "h": 1920,
          "assets": [{ "id": "image_0", "w": 540, "h": 960, "u": "images/", "p": "img.png", "e": 0 }],
          "layers": [
            { "ty": 3, "ind": 10, "nm": "mediaInput",
              "ks": { "o": { "a": 0, "k": 100 } },
              "ip": 0, "op": 300, "st": 0
            },
            { "ty": 2, "ind": 1, "nm": "media", "refId": "image_0",
              "ks": { "o": { "a": 0, "k": 100 } },
              "ip": 0, "op": 300, "st": 0
            }
          ]
        }
        """
        let report = try validateAnim(anim)

        let notShape = report.warnings.first { $0.code == AnimValidationCode.mediaInputNotShape }
        XCTAssertNotNil(notShape, "Should report MEDIA_INPUT_NOT_SHAPE when ty != 4")
    }

    // MARK: - MEDIA_INPUT_NO_PATH

    func testValidate_mediaInputNoShapes_returnsNoPathError() throws {
        // mediaInput with empty shapes array
        let anim = animWithMediaInput(
            mediaInputShapes: """
            { "ty": "gr", "it": [
              { "ty": "fl", "c": { "a": 0, "k": [0,0,0,1] }, "o": { "a": 0, "k": 100 } }
            ]}
            """,
            mediaInRoot: true
        )
        let report = try validateAnim(anim)

        let noPath = report.warnings.first { $0.code == AnimValidationCode.mediaInputNoPath }
        XCTAssertNotNil(noPath, "Should report MEDIA_INPUT_NO_PATH when no shape paths exist")
    }

    // MARK: - MEDIA_INPUT_MULTIPLE_PATHS

    func testValidate_mediaInputMultiplePaths_returnsMultiplePathsError() throws {
        // Two shape paths in the group
        let anim = animWithMediaInput(
            mediaInputShapes: """
            { "ty": "gr", "it": [
              { "ty": "sh", "ks": \(Self.rectPathJSON) },
              { "ty": "sh", "ks": \(Self.rectPathJSON) },
              { "ty": "fl", "c": { "a": 0, "k": [0,0,0,1] }, "o": { "a": 0, "k": 100 } }
            ]}
            """,
            mediaInRoot: true
        )
        let report = try validateAnim(anim)

        let multiple = report.warnings.first { $0.code == AnimValidationCode.mediaInputMultiplePaths }
        XCTAssertNotNil(multiple, "Should report MEDIA_INPUT_MULTIPLE_PATHS when more than one sh exists")
    }

    // MARK: - MEDIA_INPUT_NOT_IN_SAME_COMP

    func testValidate_mediaInputDifferentComp_returnsNotInSameCompError() throws {
        // mediaInput in root, media in precomp
        let anim = animWithMediaInput(mediaInputInRoot: true)
        let report = try validateAnim(anim)

        let notSameComp = report.warnings.first { $0.code == AnimValidationCode.mediaInputNotInSameComp }
        XCTAssertNotNil(notSameComp, "Should report MEDIA_INPUT_NOT_IN_SAME_COMP")
    }

    // MARK: - MEDIA_INPUT_FORBIDDEN_MODIFIER

    func testValidate_mediaInputWithTrimPaths_returnsForbiddenModifierError() throws {
        // mediaInput with tm (Trim Paths) modifier
        let anim = animWithMediaInput(
            mediaInputShapes: """
            { "ty": "gr", "it": [
              { "ty": "sh", "ks": \(Self.rectPathJSON) },
              { "ty": "fl", "c": { "a": 0, "k": [0,0,0,1] }, "o": { "a": 0, "k": 100 } },
              { "ty": "tm", "s": { "a": 0, "k": 0 }, "e": { "a": 0, "k": 100 }, "o": { "a": 0, "k": 0 } }
            ]}
            """,
            mediaInRoot: true
        )
        let report = try validateAnim(anim)

        let forbidden = report.warnings.first { $0.code == AnimValidationCode.mediaInputForbiddenModifier }
        XCTAssertNotNil(forbidden, "Should report MEDIA_INPUT_FORBIDDEN_MODIFIER for tm")
        XCTAssertTrue(forbidden?.message.contains("tm") ?? false)
    }

    func testValidate_mediaInputWithMergePaths_returnsForbiddenModifierError() throws {
        // mm (Merge Paths)
        let anim = animWithMediaInput(
            mediaInputShapes: """
            { "ty": "gr", "it": [
              { "ty": "sh", "ks": \(Self.rectPathJSON) },
              { "ty": "fl", "c": { "a": 0, "k": [0,0,0,1] }, "o": { "a": 0, "k": 100 } },
              { "ty": "mm", "mm": 1 }
            ]}
            """,
            mediaInRoot: true
        )
        let report = try validateAnim(anim)

        let forbidden = report.warnings.first { $0.code == AnimValidationCode.mediaInputForbiddenModifier }
        XCTAssertNotNil(forbidden, "Should report MEDIA_INPUT_FORBIDDEN_MODIFIER for mm")
    }

    func testValidate_mediaInputWithRepeater_returnsForbiddenModifierError() throws {
        // rp (Repeater)
        let anim = animWithMediaInput(
            mediaInputShapes: """
            { "ty": "gr", "it": [
              { "ty": "sh", "ks": \(Self.rectPathJSON) },
              { "ty": "fl", "c": { "a": 0, "k": [0,0,0,1] }, "o": { "a": 0, "k": 100 } },
              { "ty": "rp", "c": { "a": 0, "k": 3 } }
            ]}
            """,
            mediaInRoot: true
        )
        let report = try validateAnim(anim)

        let forbidden = report.warnings.first { $0.code == AnimValidationCode.mediaInputForbiddenModifier }
        XCTAssertNotNil(forbidden, "Should report MEDIA_INPUT_FORBIDDEN_MODIFIER for rp")
    }
}
