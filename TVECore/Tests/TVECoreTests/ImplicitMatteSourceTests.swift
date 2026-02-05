import XCTest
@testable import TVECore

/// PR-29: Tests for implicit `tp` matte sources and matte chains.
///
/// Covers:
/// - Compiler: tp-target without td=1 becomes implicit matte source
/// - Compiler: matte chain (source is itself a consumer of another matte)
/// - Golden fixture: polaroid_full.json with real matte chain topology
/// - Renderer: matte chain produces correct nested matteScope commands
/// - Validator: tp-target without td=1 produces no error
/// - Negative: tp not found and invalid order remain fatal
final class ImplicitMatteSourceTests: XCTestCase {
    private var compiler: AnimIRCompiler!

    override func setUp() {
        super.setUp()
        compiler = AnimIRCompiler()
    }

    override func tearDown() {
        compiler = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Compiles inline Lottie JSON with default binding key "media"
    private func compileLottie(_ jsonString: String) throws -> AnimIR {
        let data = jsonString.data(using: .utf8)!
        let lottie = try JSONDecoder().decode(LottieJSON.self, from: data)

        var registry = PathRegistry()
        return try compiler.compile(
            lottie: lottie,
            animRef: "test.json",
            bindingKey: "media",
            assetIndex: AssetIndex(byId: [:]),
            pathRegistry: &registry
        )
    }

    /// Finds a layer by ID across all compositions in the IR
    private func findLayer(id: LayerID, in ir: AnimIR) -> Layer? {
        for comp in ir.comps.values {
            if let layer = comp.layers.first(where: { $0.id == id }) {
                return layer
            }
        }
        return nil
    }

    // MARK: - 1. Compiler: tp-target without td=1 is accepted as implicit source

    func testCompiler_tpTargetWithoutTd_isAccepted_andBecomesImplicitSource() throws {
        // source (ind=1, NO td=1) ← consumer (ind=2, tt=1, tp=1)
        let json = """
        {
          "v":"5.12.1","fr":30,"ip":0,"op":90,"w":1080,"h":1920,"nm":"T","ddd":0,
          "assets":[{"id":"image_0","w":100,"h":100,"u":"",
            "p":"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==","e":1}],
          "layers":[
            {"ddd":0,"ind":1,"ty":2,"nm":"media","refId":"image_0","sr":1,
             "ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[0,0,0]},"a":{"a":0,"k":[0,0,0]},"s":{"a":0,"k":[100,100,100]}},
             "ip":0,"op":90,"st":0,"bm":0},
            {"ddd":0,"ind":2,"ty":2,"nm":"consumer","tt":1,"tp":1,"refId":"image_0","sr":1,
             "ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[0,0,0]},"a":{"a":0,"k":[0,0,0]},"s":{"a":0,"k":[100,100,100]}},
             "ip":0,"op":90,"st":0,"bm":0}
          ],"markers":[]
        }
        """

        let ir = try compileLottie(json)
        let rootComp = ir.comps[AnimIR.rootCompId]!

        // Consumer has matte pointing to layer 1
        let consumer = rootComp.layers.first { $0.id == 2 }
        XCTAssertNotNil(consumer?.matte)
        XCTAssertEqual(consumer?.matte?.sourceLayerId, 1)

        // Source layer 1 is flagged as implicit matte source
        let source = rootComp.layers.first { $0.id == 1 }
        XCTAssertTrue(source?.isMatteSource == true,
            "tp-target without td=1 should be flagged as isMatteSource")
    }

    // MARK: - 2. Compiler: matte chain — tp-target is itself a consumer

    func testCompiler_matteChain_tpTargetIsConsumer_compiles() throws {
        // mask(ind=1, td=1) ← plastik(ind=2, tt=1, tp=1) ← mediaInput(ind=3, tt=1, tp=2)
        // plastik is consumer of mask AND implicit source for mediaInput
        let json = """
        {
          "v":"5.12.1","fr":30,"ip":0,"op":90,"w":1080,"h":1920,"nm":"T","ddd":0,
          "assets":[{"id":"image_0","w":100,"h":100,"u":"",
            "p":"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==","e":1}],
          "layers":[
            {"ddd":0,"ind":1,"ty":4,"nm":"mask","td":1,"sr":1,
             "ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[0,0,0]},"a":{"a":0,"k":[0,0,0]},"s":{"a":0,"k":[100,100,100]}},
             "shapes":[{"ty":"gr","it":[
               {"ty":"sh","ks":{"a":0,"k":{"v":[[0,0],[100,0],[100,100],[0,100]],"i":[[0,0],[0,0],[0,0],[0,0]],"o":[[0,0],[0,0],[0,0],[0,0]],"c":true}}},
               {"ty":"fl","c":{"a":0,"k":[1,1,1,1]},"o":{"a":0,"k":100}}
             ]}],
             "ip":0,"op":90,"st":0,"bm":0},
            {"ddd":0,"ind":2,"ty":2,"nm":"media","tt":1,"tp":1,"refId":"image_0","sr":1,
             "ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[0,0,0]},"a":{"a":0,"k":[0,0,0]},"s":{"a":0,"k":[100,100,100]}},
             "ip":0,"op":90,"st":0,"bm":0},
            {"ddd":0,"ind":3,"ty":2,"nm":"consumer2","tt":1,"tp":2,"refId":"image_0","sr":1,
             "ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[0,0,0]},"a":{"a":0,"k":[0,0,0]},"s":{"a":0,"k":[100,100,100]}},
             "ip":0,"op":90,"st":0,"bm":0}
          ],"markers":[]
        }
        """

        let ir = try compileLottie(json)
        let rootComp = ir.comps[AnimIR.rootCompId]!

        // mask (ind=1) is explicit matte source
        let mask = rootComp.layers.first { $0.id == 1 }
        XCTAssertTrue(mask?.isMatteSource == true, "mask should be explicit matte source (td=1)")

        // media (ind=2) is consumer of mask AND implicit source for consumer2
        let media = rootComp.layers.first { $0.id == 2 }
        XCTAssertNotNil(media?.matte, "media should be matte consumer of mask")
        XCTAssertEqual(media?.matte?.sourceLayerId, 1)
        XCTAssertTrue(media?.isMatteSource == true,
            "media should be implicit matte source (tp-target of consumer2)")

        // consumer2 (ind=3) is consumer of media (chain)
        let consumer2 = rootComp.layers.first { $0.id == 3 }
        XCTAssertNotNil(consumer2?.matte, "consumer2 should have matte info")
        XCTAssertEqual(consumer2?.matte?.sourceLayerId, 2,
            "consumer2 matte source should be media (ind=2)")
    }

    // MARK: - 3. Golden fixture: polaroid_full.json compiles matte chain

    func testGoldenFixture_polaroidFull_compilesMatteChain() throws {
        guard let url = Bundle.module.url(
            forResource: "data",
            withExtension: "json",
            subdirectory: "Resources/polaroid_full"
        ) else {
            XCTFail("Could not find data.json in Resources/polaroid_full")
            return
        }

        let data = try Data(contentsOf: url)
        let lottie = try JSONDecoder().decode(LottieJSON.self, from: data)

        let assetIndex = AssetIndex(byId: [
            "image_0": "images/polaroid.png",
            "image_1": "images/plastik.png",
            "image_2": "images/Img_5.png"
        ])

        var registry = PathRegistry()
        let ir = try compiler.compile(
            lottie: lottie,
            animRef: "polaroid_full.json",
            bindingKey: "media",
            assetIndex: assetIndex,
            pathRegistry: &registry
        )

        // Find layers in comp_0
        guard let comp0 = ir.comps["comp_0"] else {
            XCTFail("comp_0 not found in IR")
            return
        }

        // mask (ind=2, td=1) — explicit matte source
        let mask = comp0.layers.first { $0.id == 2 }
        XCTAssertNotNil(mask, "mask layer should exist")
        XCTAssertTrue(mask?.isMatteSource == true, "mask should be explicit matte source")

        // plastik (ind=3, tt=1, tp=2, hd=true) — consumer of mask, implicit source for mediaInput
        let plastik = comp0.layers.first { $0.id == 3 }
        XCTAssertNotNil(plastik, "plastik layer should exist")
        XCTAssertNotNil(plastik?.matte, "plastik should have matte (consumer of mask)")
        XCTAssertEqual(plastik?.matte?.sourceLayerId, 2, "plastik matte source = mask (ind=2)")
        XCTAssertTrue(plastik?.isMatteSource == true,
            "plastik should be implicit matte source (tp-target of mediaInput)")
        XCTAssertTrue(plastik?.isHidden == true, "plastik should have hd=true")

        // media (ind=4, tt=1, tp=2) — consumer of mask
        let media = comp0.layers.first { $0.id == 4 }
        XCTAssertNotNil(media, "media layer should exist")
        XCTAssertEqual(media?.matte?.sourceLayerId, 2, "media matte source = mask (ind=2)")

        // mediaInput (ind=5, tt=1, tp=3) — consumer of plastik (implicit source)
        let mediaInput = comp0.layers.first { $0.id == 5 }
        XCTAssertNotNil(mediaInput, "mediaInput layer should exist")
        XCTAssertNotNil(mediaInput?.matte, "mediaInput should have matte (consumer of plastik)")
        XCTAssertEqual(mediaInput?.matte?.sourceLayerId, 3,
            "mediaInput matte source = plastik (ind=3)")
    }

    // MARK: - 4. Renderer: matte chain produces nested matteScope

    func testRenderer_matteChain_producesNestedMatteScope() throws {
        // mask(ind=1,td=1) ← plastik(ind=2,tt=1,tp=1) ← consumer(ind=3,tt=1,tp=2)
        let json = """
        {
          "v":"5.12.1","fr":30,"ip":0,"op":90,"w":1080,"h":1920,"nm":"T","ddd":0,
          "assets":[{"id":"image_0","w":100,"h":100,"u":"",
            "p":"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==","e":1}],
          "layers":[
            {"ddd":0,"ind":1,"ty":4,"nm":"mask","td":1,"sr":1,
             "ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[0,0,0]},"a":{"a":0,"k":[0,0,0]},"s":{"a":0,"k":[100,100,100]}},
             "shapes":[{"ty":"gr","it":[
               {"ty":"sh","ks":{"a":0,"k":{"v":[[0,0],[100,0],[100,100],[0,100]],"i":[[0,0],[0,0],[0,0],[0,0]],"o":[[0,0],[0,0],[0,0],[0,0]],"c":true}}},
               {"ty":"fl","c":{"a":0,"k":[1,1,1,1]},"o":{"a":0,"k":100}}
             ]}],
             "ip":0,"op":90,"st":0,"bm":0},
            {"ddd":0,"ind":2,"ty":2,"nm":"media","tt":1,"tp":1,"refId":"image_0","sr":1,
             "ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[0,0,0]},"a":{"a":0,"k":[0,0,0]},"s":{"a":0,"k":[100,100,100]}},
             "ip":0,"op":90,"st":0,"bm":0},
            {"ddd":0,"ind":3,"ty":2,"nm":"consumer2","tt":1,"tp":2,"refId":"image_0","sr":1,
             "ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[0,0,0]},"a":{"a":0,"k":[0,0,0]},"s":{"a":0,"k":[100,100,100]}},
             "ip":0,"op":90,"st":0,"bm":0}
          ],"markers":[]
        }
        """

        var ir = try compileLottie(json)
        let commands = ir.renderCommands(frameIndex: 0)

        // Should have nested matte structure:
        // consumer2's matte scope → matteSource group → media's matte scope → matteSource group → mask
        let beginMatteCount = commands.filter {
            if case .beginMatte = $0 { return true }
            return false
        }.count

        let endMatteCount = commands.filter {
            if case .endMatte = $0 { return true }
            return false
        }.count

        // consumer2 uses media as source, media uses mask as source → 2 matte scopes
        XCTAssertEqual(beginMatteCount, 2,
            "Matte chain should produce 2 nested beginMatte commands")
        XCTAssertEqual(endMatteCount, 2,
            "Matte chain should produce 2 nested endMatte commands")

        // Verify matteSource group names appear (both inner and outer)
        let groupNames = commands.compactMap { cmd -> String? in
            if case .beginGroup(let name) = cmd { return name }
            return nil
        }
        let matteSourceGroups = groupNames.filter { $0 == "matteSource" }
        let matteConsumerGroups = groupNames.filter { $0 == "matteConsumer" }
        XCTAssertEqual(matteSourceGroups.count, 2, "Should have 2 matteSource groups")
        XCTAssertEqual(matteConsumerGroups.count, 2, "Should have 2 matteConsumer groups")
    }

    // MARK: - 5. Renderer: implicit source not rendered in main pass

    func testRenderer_implicitSource_skippedInMainPass() throws {
        // source (ind=1, no td) ← consumer (ind=2, tt=1, tp=1)
        // source should NOT appear as direct drawImage in main pass
        let json = """
        {
          "v":"5.12.1","fr":30,"ip":0,"op":90,"w":1080,"h":1920,"nm":"T","ddd":0,
          "assets":[{"id":"image_0","w":100,"h":100,"u":"",
            "p":"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==","e":1}],
          "layers":[
            {"ddd":0,"ind":1,"ty":2,"nm":"media","refId":"image_0","sr":1,
             "ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[0,0,0]},"a":{"a":0,"k":[0,0,0]},"s":{"a":0,"k":[100,100,100]}},
             "ip":0,"op":90,"st":0,"bm":0},
            {"ddd":0,"ind":2,"ty":2,"nm":"consumer","tt":1,"tp":1,"refId":"image_0","sr":1,
             "ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[0,0,0]},"a":{"a":0,"k":[0,0,0]},"s":{"a":0,"k":[100,100,100]}},
             "ip":0,"op":90,"st":0,"bm":0}
          ],"markers":[]
        }
        """

        var ir = try compileLottie(json)

        // Verify the source layer is flagged
        let rootComp = ir.comps[AnimIR.rootCompId]!
        let source = rootComp.layers.first { $0.id == 1 }
        XCTAssertTrue(source?.isMatteSource == true)

        // Render and check: source should only appear inside matteSource group, not as top-level draw
        let commands = ir.renderCommands(frameIndex: 0)

        // The source layer should be rendered inside matteSource group (within matte scope)
        // but not directly in the main pass
        var insideMatteSource = false
        var drawsOutsideMatte = 0
        var drawsInsideMatte = 0

        for cmd in commands {
            if case .beginGroup(let name) = cmd, name == "matteSource" {
                insideMatteSource = true
            } else if case .endGroup = cmd, insideMatteSource {
                insideMatteSource = false
            } else if case .drawImage(let assetId, _) = cmd,
                      assetId == "test.json|image_0" {
                if insideMatteSource {
                    drawsInsideMatte += 1
                } else {
                    drawsOutsideMatte += 1
                }
            }
        }

        XCTAssertEqual(drawsInsideMatte, 1,
            "Source should be drawn once inside matteSource group")
        // Consumer draws in matteConsumer group (also inside matte scope), but source should NOT be drawn outside
        // The only drawImage outside matteSource is from the consumer in matteConsumer
        XCTAssertEqual(drawsOutsideMatte, 1,
            "Only consumer should draw outside matteSource group (in matteConsumer)")
    }

    // MARK: - 6. Validator: tp-target without td=1 produces no error

    func testValidator_tpTargetWithoutTd_noMattePairErrors() throws {
        let validator = AnimValidator()
        let layers = makeLottieLayers([
            (ind: 1, ty: 2, nm: "source", td: nil, tt: nil, tp: nil),
            (ind: 2, ty: 2, nm: "consumer", td: nil, tt: 1, tp: 1),
        ])

        var issues: [ValidationIssue] = []
        validator.validateMattePairs(layers: layers, context: "layers", animRef: "test.json", issues: &issues)

        let errors = issues.filter { $0.severity == .error }
        XCTAssertTrue(errors.isEmpty,
            "tp-target without td=1 should produce no errors, got: \(errors)")
    }

    // MARK: - 7. Validator: matte chain (source is consumer) produces no error

    func testValidator_matteChain_sourceIsConsumer_noError() throws {
        let validator = AnimValidator()
        let layers = makeLottieLayers([
            (ind: 1, ty: 4, nm: "mask", td: 1, tt: nil, tp: nil),
            (ind: 2, ty: 2, nm: "plastik", td: nil, tt: 1, tp: 1),
            (ind: 3, ty: 2, nm: "consumer", td: nil, tt: 1, tp: 2),
        ])

        var issues: [ValidationIssue] = []
        validator.validateMattePairs(layers: layers, context: "layers", animRef: "test.json", issues: &issues)

        let errors = issues.filter { $0.severity == .error }
        XCTAssertTrue(errors.isEmpty,
            "Matte chain (source is consumer) should produce no errors, got: \(errors)")
    }

    // MARK: - 8. Negative: tp target not found remains fatal

    func testCompiler_tpTargetNotFound_stillThrows() throws {
        let json = """
        {
          "v":"5.12.1","fr":30,"ip":0,"op":90,"w":1080,"h":1920,"nm":"T","ddd":0,
          "assets":[{"id":"image_0","w":100,"h":100,"u":"",
            "p":"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==","e":1}],
          "layers":[
            {"ddd":0,"ind":1,"ty":2,"nm":"media","refId":"image_0","sr":1,
             "ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[0,0,0]},"a":{"a":0,"k":[0,0,0]},"s":{"a":0,"k":[100,100,100]}},
             "ip":0,"op":90,"st":0,"bm":0},
            {"ddd":0,"ind":2,"ty":2,"nm":"consumer","tt":1,"tp":99,"refId":"image_0","sr":1,
             "ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[0,0,0]},"a":{"a":0,"k":[0,0,0]},"s":{"a":0,"k":[100,100,100]}},
             "ip":0,"op":90,"st":0,"bm":0}
          ],"markers":[]
        }
        """

        XCTAssertThrowsError(try compileLottie(json)) { error in
            guard case AnimIRCompilerError.matteTargetNotFound(let tp, _, _) = error else {
                XCTFail("Expected matteTargetNotFound, got: \(error)")
                return
            }
            XCTAssertEqual(tp, 99)
        }
    }

    // MARK: - 9. Negative: tp invalid order remains fatal

    func testCompiler_tpTargetInvalidOrder_stillThrows() throws {
        let json = """
        {
          "v":"5.12.1","fr":30,"ip":0,"op":90,"w":1080,"h":1920,"nm":"T","ddd":0,
          "assets":[{"id":"image_0","w":100,"h":100,"u":"",
            "p":"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==","e":1}],
          "layers":[
            {"ddd":0,"ind":1,"ty":2,"nm":"media","refId":"image_0","sr":1,
             "ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[0,0,0]},"a":{"a":0,"k":[0,0,0]},"s":{"a":0,"k":[100,100,100]}},
             "ip":0,"op":90,"st":0,"bm":0},
            {"ddd":0,"ind":2,"ty":2,"nm":"consumer","tt":1,"tp":3,"refId":"image_0","sr":1,
             "ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[0,0,0]},"a":{"a":0,"k":[0,0,0]},"s":{"a":0,"k":[100,100,100]}},
             "ip":0,"op":90,"st":0,"bm":0},
            {"ddd":0,"ind":3,"ty":4,"nm":"source","td":1,"sr":1,
             "ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[0,0,0]},"a":{"a":0,"k":[0,0,0]},"s":{"a":0,"k":[100,100,100]}},
             "shapes":[{"ty":"gr","it":[
               {"ty":"sh","ks":{"a":0,"k":{"v":[[0,0],[100,0],[100,100],[0,100]],"i":[[0,0],[0,0],[0,0],[0,0]],"o":[[0,0],[0,0],[0,0],[0,0]],"c":true}}},
               {"ty":"fl","c":{"a":0,"k":[1,1,1,1]},"o":{"a":0,"k":100}}
             ]}],
             "ip":0,"op":90,"st":0,"bm":0}
          ],"markers":[]
        }
        """

        XCTAssertThrowsError(try compileLottie(json)) { error in
            guard case AnimIRCompilerError.matteTargetInvalidOrder(let tp, _, _) = error else {
                XCTFail("Expected matteTargetInvalidOrder, got: \(error)")
                return
            }
            XCTAssertEqual(tp, 3)
        }
    }

    // MARK: - LottieLayer Factory

    private func makeLottieLayers(
        _ specs: [(ind: Int, ty: Int, nm: String, td: Int?, tt: Int?, tp: Int?)]
    ) -> [LottieLayer] {
        specs.map { spec in
            LottieLayer(
                type: spec.ty,
                name: spec.nm,
                index: spec.ind,
                trackMatteType: spec.tt,
                isMatteSource: spec.td,
                matteTarget: spec.tp
            )
        }
    }
}
