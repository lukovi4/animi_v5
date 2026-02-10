import XCTest
@testable import TVECore
@testable import TVECompilerCore

/// Tests for PR-27: tp-based track matte resolution (shared matte support).
///
/// Covers:
/// - Compiler: tp-based shared matte (1 source → N consumers), legacy adjacency fallback
/// - Compiler: error cases (target not found, target not source, invalid order)
/// - Validator: tp-based validation + legacy adjacency fallback
/// - Golden fixture: real data.json with polaroid template (2 consumers → 1 source)
final class SharedMatteTests: XCTestCase {
    private var compiler: AnimIRCompiler!

    override func setUp() {
        super.setUp()
        compiler = AnimIRCompiler()
    }

    override func tearDown() {
        compiler = nil
        super.tearDown()
    }

    // MARK: - Synthetic JSON Constants

    /// Shared matte: 1 source (td=1, ind=2) → 2 non-adjacent consumers (tp=2)
    /// Layer order: [source(ind=2), other(ind=5), consumerA(ind=3,tp=2), consumerB(ind=4,tp=2)]
    /// consumerA is NOT adjacent to source — adjacency-only would fail.
    private static let sharedMatteJSON = """
    {
      "v": "5.12.1", "fr": 30, "ip": 0, "op": 90,
      "w": 1080, "h": 1920, "nm": "SharedMatte", "ddd": 0,
      "assets": [
        { "id": "image_0", "w": 100, "h": 100, "u": "",
          "p": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==",
          "e": 1 }
      ],
      "layers": [
        {
          "ddd": 0, "ind": 2, "ty": 4, "nm": "matteSource", "td": 1, "sr": 1,
          "ks": { "o":{"a":0,"k":100}, "r":{"a":0,"k":0},
                  "p":{"a":0,"k":[540,960,0]}, "a":{"a":0,"k":[0,0,0]},
                  "s":{"a":0,"k":[100,100,100]} },
          "shapes": [{"ty":"gr","it":[
            {"ty":"sh","ks":{"a":0,"k":{"v":[[0,0],[100,0],[100,100],[0,100]],"i":[[0,0],[0,0],[0,0],[0,0]],"o":[[0,0],[0,0],[0,0],[0,0]],"c":true}}},
            {"ty":"fl","c":{"a":0,"k":[1,1,1,1]},"o":{"a":0,"k":100}}
          ]}],
          "ip": 0, "op": 90, "st": 0, "bm": 0
        },
        {
          "ddd": 0, "ind": 5, "ty": 2, "nm": "media", "refId": "image_0", "sr": 1,
          "ks": { "o":{"a":0,"k":100}, "r":{"a":0,"k":0},
                  "p":{"a":0,"k":[540,960,0]}, "a":{"a":0,"k":[50,50,0]},
                  "s":{"a":0,"k":[100,100,100]} },
          "ip": 0, "op": 90, "st": 0, "bm": 0
        },
        {
          "ddd": 0, "ind": 3, "ty": 2, "nm": "consumerA", "tt": 1, "tp": 2,
          "refId": "image_0", "sr": 1,
          "ks": { "o":{"a":0,"k":100}, "r":{"a":0,"k":0},
                  "p":{"a":0,"k":[540,960,0]}, "a":{"a":0,"k":[50,50,0]},
                  "s":{"a":0,"k":[100,100,100]} },
          "ip": 0, "op": 90, "st": 0, "bm": 0
        },
        {
          "ddd": 0, "ind": 4, "ty": 2, "nm": "consumerB", "tt": 2, "tp": 2,
          "refId": "image_0", "sr": 1,
          "ks": { "o":{"a":0,"k":100}, "r":{"a":0,"k":0},
                  "p":{"a":0,"k":[540,960,0]}, "a":{"a":0,"k":[50,50,0]},
                  "s":{"a":0,"k":[100,100,100]} },
          "ip": 0, "op": 90, "st": 0, "bm": 0
        }
      ],
      "markers": []
    }
    """

    /// Legacy adjacency matte: source(td=1) immediately followed by consumer(tt=1, no tp)
    private static let legacyAdjacencyMatteJSON = """
    {
      "v": "5.12.1", "fr": 30, "ip": 0, "op": 90,
      "w": 1080, "h": 1920, "nm": "LegacyMatte", "ddd": 0,
      "assets": [
        { "id": "image_0", "w": 100, "h": 100, "u": "",
          "p": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==",
          "e": 1 }
      ],
      "layers": [
        {
          "ddd": 0, "ind": 1, "ty": 2, "nm": "media", "refId": "image_0", "sr": 1,
          "ks": { "o":{"a":0,"k":100}, "r":{"a":0,"k":0},
                  "p":{"a":0,"k":[540,960,0]}, "a":{"a":0,"k":[50,50,0]},
                  "s":{"a":0,"k":[100,100,100]} },
          "ip": 0, "op": 90, "st": 0, "bm": 0
        },
        {
          "ddd": 0, "ind": 2, "ty": 4, "nm": "matteSource", "td": 1, "sr": 1,
          "ks": { "o":{"a":0,"k":100}, "r":{"a":0,"k":0},
                  "p":{"a":0,"k":[540,960,0]}, "a":{"a":0,"k":[0,0,0]},
                  "s":{"a":0,"k":[100,100,100]} },
          "shapes": [{"ty":"gr","it":[
            {"ty":"sh","ks":{"a":0,"k":{"v":[[0,0],[100,0],[100,100],[0,100]],"i":[[0,0],[0,0],[0,0],[0,0]],"o":[[0,0],[0,0],[0,0],[0,0]],"c":true}}},
            {"ty":"fl","c":{"a":0,"k":[1,1,1,1]},"o":{"a":0,"k":100}}
          ]}],
          "ip": 0, "op": 90, "st": 0, "bm": 0
        },
        {
          "ddd": 0, "ind": 3, "ty": 2, "nm": "consumer", "tt": 1,
          "refId": "image_0", "sr": 1,
          "ks": { "o":{"a":0,"k":100}, "r":{"a":0,"k":0},
                  "p":{"a":0,"k":[540,960,0]}, "a":{"a":0,"k":[50,50,0]},
                  "s":{"a":0,"k":[100,100,100]} },
          "ip": 0, "op": 90, "st": 0, "bm": 0
        }
      ],
      "markers": []
    }
    """

    // MARK: - Helpers

    private func compileLottie(_ json: String, bindingKey: String = "media") throws -> AnimIR {
        let data = json.data(using: .utf8)!
        let lottie = try JSONDecoder().decode(LottieJSON.self, from: data)
        let assetIndex = AssetIndex(byId: [:])
        var registry = PathRegistry()
        return try compiler.compile(
            lottie: lottie,
            animRef: "test.json",
            bindingKey: bindingKey,
            assetIndex: assetIndex,
            pathRegistry: &registry
        )
    }

    private func findLayer(id: LayerID, in ir: AnimIR) -> Layer? {
        for comp in ir.comps.values {
            if let layer = comp.layers.first(where: { $0.id == id }) {
                return layer
            }
        }
        return nil
    }

    // MARK: - Compiler: tp-based shared matte

    /// Core test: two non-adjacent consumers with tp=2 both get sourceLayerId == 2
    func testCompiler_sharedMatte_tpBased_bothConsumersLinked() throws {
        let ir = try compileLottie(Self.sharedMatteJSON)

        // consumerA (ind=3) and consumerB (ind=4) must both reference source ind=2
        let consumerA = findLayer(id: 3, in: ir)
        let consumerB = findLayer(id: 4, in: ir)

        XCTAssertNotNil(consumerA, "consumerA (ind=3) should exist")
        XCTAssertNotNil(consumerB, "consumerB (ind=4) should exist")

        XCTAssertNotNil(consumerA?.matte, "consumerA should have matte info")
        XCTAssertNotNil(consumerB?.matte, "consumerB should have matte info")

        XCTAssertEqual(consumerA?.matte?.sourceLayerId, 2,
            "consumerA.matte.sourceLayerId should be 2 (the shared source)")
        XCTAssertEqual(consumerB?.matte?.sourceLayerId, 2,
            "consumerB.matte.sourceLayerId should be 2 (the shared source)")

        // Verify matte modes
        XCTAssertEqual(consumerA?.matte?.mode, .alpha,
            "consumerA should have alpha matte (tt=1)")
        XCTAssertEqual(consumerB?.matte?.mode, .alphaInverted,
            "consumerB should have alphaInverted matte (tt=2)")
    }

    /// Source layer must be flagged as matteSource
    func testCompiler_sharedMatte_sourceIsFlagged() throws {
        let ir = try compileLottie(Self.sharedMatteJSON)

        let source = findLayer(id: 2, in: ir)
        XCTAssertNotNil(source, "source (ind=2) should exist")
        XCTAssertTrue(source?.isMatteSource == true, "source should have isMatteSource=true")
    }

    /// Non-consumer layer (ind=5) should have no matte
    func testCompiler_sharedMatte_nonConsumerHasNoMatte() throws {
        let ir = try compileLottie(Self.sharedMatteJSON)

        let other = findLayer(id: 5, in: ir)
        XCTAssertNotNil(other, "other layer (ind=5) should exist")
        XCTAssertNil(other?.matte, "non-consumer layer should have no matte info")
    }

    // MARK: - Compiler: Legacy adjacency fallback

    /// When tp is absent, legacy adjacency (previous layer td=1) still works
    func testCompiler_legacyAdjacency_consumerLinkedToAdjacentSource() throws {
        let ir = try compileLottie(Self.legacyAdjacencyMatteJSON)

        let consumer = findLayer(id: 3, in: ir)
        XCTAssertNotNil(consumer?.matte, "consumer should have matte info via legacy adjacency")
        XCTAssertEqual(consumer?.matte?.sourceLayerId, 2,
            "consumer.matte.sourceLayerId should be 2 via adjacency")
        XCTAssertEqual(consumer?.matte?.mode, .alpha, "consumer should have alpha matte (tt=1)")
    }

    // MARK: - Compiler: Error cases

    /// tp points to non-existent ind → matteTargetNotFound
    func testCompiler_tpTargetNotFound_throws() throws {
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

    /// PR-29: tp points to layer without td=1 → compiles successfully (implicit source)
    func testCompiler_tpTargetWithoutTd_isAccepted_asImplicitSource() throws {
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

        // Consumer should have matte pointing to layer 1
        let consumer = rootComp.layers.first { $0.id == 2 }
        XCTAssertNotNil(consumer?.matte, "Consumer should have matte info")
        XCTAssertEqual(consumer?.matte?.sourceLayerId, 1)

        // Target layer 1 should be flagged as implicit matte source
        let source = rootComp.layers.first { $0.id == 1 }
        XCTAssertTrue(source?.isMatteSource == true,
            "tp-target without td=1 should be flagged as implicit matte source")
    }

    /// tp points to source that appears AFTER consumer → matteTargetInvalidOrder
    func testCompiler_tpTargetInvalidOrder_throws() throws {
        let json = """
        {
          "v":"5.12.1","fr":30,"ip":0,"op":90,"w":1080,"h":1920,"nm":"T","ddd":0,
          "assets":[{"id":"image_0","w":100,"h":100,"u":"",
            "p":"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==","e":1}],
          "layers":[
            {"ddd":0,"ind":1,"ty":2,"nm":"media","refId":"image_0","sr":1,
             "ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[0,0,0]},"a":{"a":0,"k":[0,0,0]},"s":{"a":0,"k":[100,100,100]}},
             "ip":0,"op":90,"st":0,"bm":0},
            {"ddd":0,"ind":3,"ty":2,"nm":"consumer","tt":1,"tp":2,"refId":"image_0","sr":1,
             "ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[0,0,0]},"a":{"a":0,"k":[0,0,0]},"s":{"a":0,"k":[100,100,100]}},
             "ip":0,"op":90,"st":0,"bm":0},
            {"ddd":0,"ind":2,"ty":4,"nm":"source","td":1,"sr":1,
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
            XCTAssertEqual(tp, 2)
        }
    }

    // MARK: - Validator: tp-based tests

    func testValidator_tpTargetNotFound_returnsError() throws {
        let validator = AnimValidator()
        let layers = makeLottieLayers([
            (ind: 1, ty: 2, nm: "layer1", td: nil, tt: nil, tp: nil),
            (ind: 2, ty: 2, nm: "consumer", td: nil, tt: 1, tp: 99),
        ])

        var issues: [ValidationIssue] = []
        validator.validateMattePairs(layers: layers, context: "layers", animRef: "test.json", issues: &issues)

        let error = issues.first { $0.code == AnimValidationCode.matteTargetNotFound }
        XCTAssertNotNil(error, "Should produce MATTE_TARGET_NOT_FOUND")
        XCTAssertTrue(error?.path.contains(".tp") == true)
    }

    /// PR-29: tp-target without td=1 is accepted (implicit source) — no error
    func testValidator_tpTargetWithoutTd_noError() throws {
        let validator = AnimValidator()
        let layers = makeLottieLayers([
            (ind: 1, ty: 2, nm: "notSource", td: nil, tt: nil, tp: nil),
            (ind: 2, ty: 2, nm: "consumer", td: nil, tt: 1, tp: 1),
        ])

        var issues: [ValidationIssue] = []
        validator.validateMattePairs(layers: layers, context: "layers", animRef: "test.json", issues: &issues)

        let errors = issues.filter { $0.severity == .error }
        XCTAssertTrue(errors.isEmpty, "tp-target without td=1 should not produce errors, got: \(errors)")
    }

    func testValidator_tpTargetInvalidOrder_returnsError() throws {
        let validator = AnimValidator()
        let layers = makeLottieLayers([
            (ind: 1, ty: 2, nm: "consumer", td: nil, tt: 1, tp: 2),
            (ind: 2, ty: 4, nm: "source", td: 1, tt: nil, tp: nil),
        ])

        var issues: [ValidationIssue] = []
        validator.validateMattePairs(layers: layers, context: "layers", animRef: "test.json", issues: &issues)

        let error = issues.first { $0.code == AnimValidationCode.matteTargetInvalidOrder }
        XCTAssertNotNil(error, "Should produce MATTE_TARGET_INVALID_ORDER")
    }

    func testValidator_tpValid_sharedMatte_noErrors() throws {
        let validator = AnimValidator()
        let layers = makeLottieLayers([
            (ind: 2, ty: 4, nm: "source", td: 1, tt: nil, tp: nil),
            (ind: 3, ty: 2, nm: "consumerA", td: nil, tt: 1, tp: 2),
            (ind: 4, ty: 2, nm: "consumerB", td: nil, tt: 2, tp: 2),
        ])

        var issues: [ValidationIssue] = []
        validator.validateMattePairs(layers: layers, context: "layers", animRef: "test.json", issues: &issues)

        let matteErrors = issues.filter { $0.severity == .error }
        XCTAssertTrue(matteErrors.isEmpty,
            "Valid shared matte should produce no errors, got: \(matteErrors)")
    }

    func testValidator_legacyAdjacency_stillWorks() throws {
        let validator = AnimValidator()
        let layers = makeLottieLayers([
            (ind: 1, ty: 4, nm: "source", td: 1, tt: nil, tp: nil),
            (ind: 2, ty: 2, nm: "consumer", td: nil, tt: 1, tp: nil),
        ])

        var issues: [ValidationIssue] = []
        validator.validateMattePairs(layers: layers, context: "layers", animRef: "test.json", issues: &issues)

        let matteErrors = issues.filter { $0.severity == .error }
        XCTAssertTrue(matteErrors.isEmpty,
            "Legacy adjacency should produce no errors, got: \(matteErrors)")
    }

    // MARK: - Golden Fixture: polaroid data.json

    /// Tests that the real polaroid template correctly links both consumers to the shared source.
    ///
    /// data.json structure:
    /// - ind=1: polaroid.png (image, no matte)
    /// - ind=2: mediaInput (shape, td=1) — MATTE SOURCE
    /// - ind=3: plastik.png (image, tt=1, tp=2) — CONSUMER A
    /// - ind=4: media (image, tt=1, tp=2) — CONSUMER B
    func testGoldenFixture_polaroidDataJSON_sharedMatte() throws {
        guard let url = Bundle.module.url(
            forResource: "data",
            withExtension: "json",
            subdirectory: "Resources/shared_matte"
        ) else {
            XCTFail("Could not find data.json in Resources/shared_matte")
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
            animRef: "polaroid/data.json",
            bindingKey: "media",
            assetIndex: assetIndex,
            pathRegistry: &registry
        )

        // plastik (ind=3) should have matte linked to source ind=2
        let plastik = findLayer(id: 3, in: ir)
        XCTAssertNotNil(plastik, "plastik layer (ind=3) should exist")
        XCTAssertNotNil(plastik?.matte, "plastik should have matte info")
        XCTAssertEqual(plastik?.matte?.sourceLayerId, 2,
            "plastik.matte.sourceLayerId should be 2 (mediaInput)")
        XCTAssertEqual(plastik?.matte?.mode, .alpha,
            "plastik should have alpha matte (tt=1)")

        // media (ind=4) should have matte linked to same source ind=2
        let media = findLayer(id: 4, in: ir)
        XCTAssertNotNil(media, "media layer (ind=4) should exist")
        XCTAssertNotNil(media?.matte, "media should have matte info")
        XCTAssertEqual(media?.matte?.sourceLayerId, 2,
            "media.matte.sourceLayerId should be 2 (mediaInput)")
        XCTAssertEqual(media?.matte?.mode, .alpha,
            "media should have alpha matte (tt=1)")

        // Both consumers reference the SAME source
        XCTAssertEqual(plastik?.matte?.sourceLayerId, media?.matte?.sourceLayerId,
            "Both consumers must reference the same matte source")

        // Source (ind=2) is flagged as matteSource
        let source = findLayer(id: 2, in: ir)
        XCTAssertTrue(source?.isMatteSource == true,
            "mediaInput (ind=2) should be flagged as matteSource")
    }

    // MARK: - Validator Negative Fixtures

    func testValidatorFixture_tpTargetNotFound_returnsError() throws {
        let report = try validateNegativeFixture("neg_matte_tp_target_not_found")

        let error = report.errors.first { $0.code == AnimValidationCode.matteTargetNotFound }
        XCTAssertNotNil(error, "Should produce MATTE_TARGET_NOT_FOUND for tp=99")
        XCTAssertTrue(error?.path.contains(".tp") == true)
    }

    /// PR-29: tp-target without td=1 is now valid (implicit source) — no error expected
    func testValidatorFixture_tpTargetNotSource_noErrorExpected() throws {
        let report = try validateNegativeFixture("neg_matte_tp_target_not_source")

        let matteErrors = report.errors.filter {
            $0.code == "MATTE_TARGET_NOT_SOURCE" || $0.code == "MATTE_TARGET_NOT_FOUND"
                || $0.code == "MATTE_TARGET_INVALID_ORDER"
        }
        XCTAssertTrue(matteErrors.isEmpty,
            "tp-target without td=1 should no longer produce matte errors, got: \(matteErrors)")
    }

    func testValidatorFixture_tpInvalidOrder_returnsError() throws {
        let report = try validateNegativeFixture("neg_matte_tp_invalid_order")

        let error = report.errors.first { $0.code == AnimValidationCode.matteTargetInvalidOrder }
        XCTAssertNotNil(error, "Should produce MATTE_TARGET_INVALID_ORDER when source is after consumer")
    }

    // MARK: - Validator Negative Fixture Helper

    private var tempDir: URL?

    override func tearDown(completion: @escaping ((any Error)?) -> Void) {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        completion(nil)
    }

    private func validateNegativeFixture(_ caseName: String) throws -> ValidationReport {
        guard let animURL = Bundle.module.url(
            forResource: "anim",
            withExtension: "json",
            subdirectory: "Resources/negative/\(caseName)"
        ) else {
            throw XCTSkip("Test resource \(caseName) not found in bundle")
        }

        let animData = try Data(contentsOf: animURL)
        let animJSONString = String(data: animData, encoding: .utf8)!

        let sceneJSON = """
        {
          "schemaVersion": "0.1",
          "canvas": { "width": 1080, "height": 1920, "fps": 30, "durationFrames": 90 },
          "mediaBlocks": [{
            "blockId": "test_block",
            "zIndex": 0,
            "rect": { "x": 0, "y": 0, "width": 1080, "height": 1920 },
            "containerClip": "slotRect",
            "input": {
              "rect": { "x": 0, "y": 0, "width": 1080, "height": 1920 },
              "bindingKey": "_test_placeholder_",
              "allowedMedia": ["photo"]
            },
            "variants": [{ "variantId": "v1", "animRef": "anim.json" }]
          }]
        }
        """

        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir!, withIntermediateDirectories: true)

        let sceneURL = tempDir!.appendingPathComponent("scene.json")
        try sceneJSON.write(to: sceneURL, atomically: true, encoding: .utf8)

        let animFileURL = tempDir!.appendingPathComponent("anim.json")
        try animJSONString.write(to: animFileURL, atomically: true, encoding: .utf8)

        let packageLoader = ScenePackageLoader()
        let package = try packageLoader.load(from: tempDir!)
        let loader = AnimLoader()
        let loaded = try loader.loadAnimations(from: package)

        return AnimValidator().validate(scene: package.scene, package: package, loaded: loaded)
    }

    // MARK: - LottieLayer Factory Helper

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
