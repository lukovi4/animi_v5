import XCTest
import Foundation
@testable import AnimiEngineCore
import AnimiEngineTestSupport

/// Real-template structural and instantiation tests (Task-002 plan §9; corrective plan C-7).
final class TemplateFixtureTests: XCTestCase {

    /// `#file` = `<repo>/AnimiEngineNext/Tests/AnimiEngineCoreTests/TemplateFixtureTests.swift`
    /// → repo root is four components up (test-only `#file` use; production injects the root).
    private func repositoryRoot() -> TemplateRepositoryRoot {
        var url = URL(fileURLWithPath: #file)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return TemplateRepositoryRoot(url: url)
    }

    private let expectedBlockCounts: [String: Int] = [
        "full_image": 1,
        "polaroid_shared_demo": 1,
        "polaroid_2": 2,
        "example_4blocks": 4,
        "6_frames_template": 6
    ]

    /// A selection that picks the first authored variant of every block.
    private func defaultSelection(_ descriptor: TemplateFixtureDescriptor) -> [String: String] {
        var selection: [String: String] = [:]
        for slot in descriptor.slots {
            selection[slot.blockID] = slot.variants.first?.variantID
        }
        return selection
    }

    func testAllFiveTemplatesParseIntoDescriptors() throws {
        let root = repositoryRoot()
        for catalogID in TemplateFixtureIndex.mandatoryCatalogIDs {
            let descriptor = try TemplateFixtureReader.read(catalogID: catalogID, root: root)
            XCTAssertEqual(descriptor.catalogID, catalogID)
            XCTAssertFalse(descriptor.slots.isEmpty)
            XCTAssertGreaterThan(descriptor.duration.ticks, 0)
        }
    }

    func testBlockCountsAre_1_1_2_4_6() throws {
        let root = repositoryRoot()
        for (catalogID, expected) in expectedBlockCounts {
            let descriptor = try TemplateFixtureReader.read(catalogID: catalogID, root: root)
            XCTAssertEqual(descriptor.slots.count, expected, "block count for \(catalogID)")
        }
    }

    func testExample4BlocksKeepsDistinctCatalogAndSceneID() throws {
        let descriptor = try TemplateFixtureReader.read(catalogID: "example_4blocks", root: repositoryRoot())
        XCTAssertEqual(descriptor.catalogID, "example_4blocks")
        XCTAssertEqual(descriptor.sceneID, "scene_test_2x2_4blocks")
        XCTAssertNotEqual(descriptor.catalogID, descriptor.sceneID)
    }

    func testRealHoldLastFrameAndCutPoliciesMapCorrectly() throws {
        let descriptor = try TemplateFixtureReader.read(catalogID: "full_image", root: repositoryRoot())
        let variant = try XCTUnwrap(descriptor.slots.first?.variants.first)
        XCTAssertEqual(variant.ifAnimationShorter, "holdLastFrame")
        XCTAssertEqual(variant.ifAnimationLonger, "cut")
        // Strict mappers: holdLastFrame + loop:false → .holdLast; cut → .cutAtEvaluationEnd.
        XCTAssertEqual(try CanonicalProjectFixtures.shorterPolicy("holdLastFrame", loop: false), .holdLast)
        XCTAssertEqual(try CanonicalProjectFixtures.longerPolicy("cut"), .cutAtEvaluationEnd)
    }

    func testEveryAuthoredVariantOfEveryBlockInstantiatesRenderComplete() throws {
        let root = repositoryRoot()
        for catalogID in TemplateFixtureIndex.mandatoryCatalogIDs {
            let descriptor = try TemplateFixtureReader.read(catalogID: catalogID, root: root)
            for slot in descriptor.slots {
                for variant in slot.variants {
                    // Selection: this variant for this block, first variant for every other block.
                    var selection = defaultSelection(descriptor)
                    selection[slot.blockID] = variant.variantID
                    let payload = try CanonicalProjectFixtures.instantiate(
                        descriptor,
                        sceneInstanceID: "\(catalogID).\(slot.blockID).\(variant.variantID)",
                        payloadID: "\(catalogID).\(slot.blockID).\(variant.variantID).pl",
                        selection: selection
                    )
                    XCTAssertEqual(payload.layers.count, descriptor.slots.count)
                    let doc = try CanonicalProjectFixtures.singleSceneDocument(
                        payload: payload, nominalDurationTicks: descriptor.duration.ticks
                    )
                    XCTAssertNoThrow(try ProjectValidator.validate(doc), "\(catalogID)/\(slot.blockID)/\(variant.variantID)")
                    let plan = try EvaluationHarness.evaluate(doc, atTick: 0)
                    guard case .single(let subplan) = plan.body else {
                        return XCTFail("expected single for \(catalogID)/\(slot.blockID)/\(variant.variantID)")
                    }
                    XCTAssertEqual(subplan.layers.count, descriptor.slots.count)
                }
            }
        }
    }

    func testMissingVariantSelectionRejected() throws {
        let descriptor = try TemplateFixtureReader.read(catalogID: "polaroid_2", root: repositoryRoot())
        var selection = defaultSelection(descriptor)
        selection.removeValue(forKey: "block_02")  // omit a block
        XCTAssertThrowsError(try CanonicalProjectFixtures.instantiate(
            descriptor, sceneInstanceID: "x", payloadID: "x.pl", selection: selection
        )) {
            XCTAssertEqual($0 as? TemplateFixtureReader.ReadError, .missingVariantSelection(blockID: "block_02"))
        }
    }

    func testUnknownVariantSelectionRejected() throws {
        let descriptor = try TemplateFixtureReader.read(catalogID: "polaroid_2", root: repositoryRoot())
        var selection = defaultSelection(descriptor)
        selection["block_01"] = "does-not-exist"
        XCTAssertThrowsError(try CanonicalProjectFixtures.instantiate(
            descriptor, sceneInstanceID: "x", payloadID: "x.pl", selection: selection
        )) {
            XCTAssertEqual($0 as? TemplateFixtureReader.ReadError, .unknownVariantSelection(blockID: "block_01", variantID: "does-not-exist"))
        }
    }

    func testUnknownPolicyRejected() {
        XCTAssertThrowsError(try CanonicalProjectFixtures.shorterPolicy("bogus", loop: false)) {
            XCTAssertEqual($0 as? TemplateFixtureReader.ReadError, .unknownShorterPolicy("bogus"))
        }
        XCTAssertThrowsError(try CanonicalProjectFixtures.longerPolicy("freeze")) {
            XCTAssertEqual($0 as? TemplateFixtureReader.ReadError, .unknownLongerPolicy("freeze"))
        }
    }

    func testContradictoryLoopPolicyRejected() {
        // loop:true with a non-loop shorter policy is contradictory.
        XCTAssertThrowsError(try CanonicalProjectFixtures.shorterPolicy("holdLastFrame", loop: true, blockID: "b", variantID: "v")) {
            XCTAssertEqual($0 as? TemplateFixtureReader.ReadError, .contradictoryLoopPolicy(blockID: "b", variantID: "v"))
        }
        // loop:false with shorter policy "loop" is contradictory.
        XCTAssertThrowsError(try CanonicalProjectFixtures.shorterPolicy("loop", loop: false, blockID: "b", variantID: "v")) {
            XCTAssertEqual($0 as? TemplateFixtureReader.ReadError, .contradictoryLoopPolicy(blockID: "b", variantID: "v"))
        }
        // loop:true with "loop" is consistent.
        XCTAssertEqual(try CanonicalProjectFixtures.shorterPolicy("loop", loop: true), .loop)
    }

    func testDefaultDurationFramesConvertedExactly() throws {
        let descriptor = try TemplateFixtureReader.read(catalogID: "full_image", root: repositoryRoot())
        let variant = try XCTUnwrap(descriptor.slots.first?.variants.first)
        // full_image is 150 frames @30 → 150 * 8000 = 1_200_000 ticks.
        XCTAssertEqual(variant.defaultDurationFrames, 150)
        let ticks = try CanonicalProjectFixtures.authoredDurationTicks(variant: variant, frameRate: descriptor.frameRate)
        XCTAssertEqual(ticks.ticks, 1_200_000)
    }

    // MARK: - Strict JSON typing (no Foundation bridging ambiguity)

    private func writeTempJSON(_ json: String) throws -> TemplateRepositoryRoot {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tmpl-\(UUID().uuidString)")
        let dir = base.appendingPathComponent("SceneSources/strict_case", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: dir.appendingPathComponent("scene.json"))
        return TemplateRepositoryRoot(url: base)
    }

    private let baseBlock = """
      "mediaBlocks": [{
        "blockId": "block_01", "zIndex": 0,
        "rect": {"x": 0, "y": 0, "width": 10, "height": 10},
        "input": {"bindingKey": "media"},
        "variants": [{"variantId": "v", "animRef": "a.json", "defaultDurationFrames": 150,
          "ifAnimationShorter": "holdLastFrame", "ifAnimationLonger": "cut", "loop": false}]
      }]
    """

    func testBoolAsNumberRejected() throws {
        // `loop` as the number 1 (not boolean true) must be rejected.
        let json = """
        {"sceneId": "s", "canvas": {"width": 1080, "height": 1920, "fps": 30, "durationFrames": 150},
         "mediaBlocks": [{
           "blockId": "block_01", "zIndex": 0,
           "rect": {"x": 0, "y": 0, "width": 10, "height": 10},
           "input": {"bindingKey": "media"},
           "variants": [{"variantId": "v", "animRef": "a.json", "defaultDurationFrames": 150,
             "ifAnimationShorter": "holdLastFrame", "ifAnimationLonger": "cut", "loop": 1}]
         }]}
        """
        let root = try writeTempJSON(json)
        XCTAssertThrowsError(try TemplateFixtureReader.read(catalogID: "strict_case", root: root)) {
            XCTAssertEqual($0 as? TemplateFixtureReader.ReadError, .wrongType(field: "loop"))
        }
    }

    func testNumberAsBoolFieldRejectedForInteger() throws {
        // `zIndex` as JSON boolean true must be rejected (not silently read as 1).
        let json = """
        {"sceneId": "s", "canvas": {"width": 1080, "height": 1920, "fps": 30, "durationFrames": 150},
         "mediaBlocks": [{
           "blockId": "block_01", "zIndex": true,
           "rect": {"x": 0, "y": 0, "width": 10, "height": 10},
           "input": {"bindingKey": "media"},
           "variants": [{"variantId": "v", "animRef": "a.json", "defaultDurationFrames": 150,
             "ifAnimationShorter": "holdLastFrame", "ifAnimationLonger": "cut", "loop": false}]
         }]}
        """
        let root = try writeTempJSON(json)
        XCTAssertThrowsError(try TemplateFixtureReader.read(catalogID: "strict_case", root: root)) {
            XCTAssertEqual($0 as? TemplateFixtureReader.ReadError, .wrongType(field: "zIndex"))
        }
    }

    func testFractionalNumberAsIntegerRejected() throws {
        let json = """
        {"sceneId": "s", "canvas": {"width": 1080, "height": 1920, "fps": 30, "durationFrames": 150},
         "mediaBlocks": [{
           "blockId": "block_01", "zIndex": 0,
           "rect": {"x": 0, "y": 0, "width": 10, "height": 10},
           "input": {"bindingKey": "media"},
           "variants": [{"variantId": "v", "animRef": "a.json", "defaultDurationFrames": 150.5,
             "ifAnimationShorter": "holdLastFrame", "ifAnimationLonger": "cut", "loop": false}]
         }]}
        """
        let root = try writeTempJSON(json)
        XCTAssertThrowsError(try TemplateFixtureReader.read(catalogID: "strict_case", root: root)) {
            XCTAssertEqual($0 as? TemplateFixtureReader.ReadError, .wrongType(field: "defaultDurationFrames"))
        }
    }

    func testStringAsNumberRejected() throws {
        let json = """
        {"sceneId": "s", "canvas": {"width": "1080", "height": 1920, "fps": 30, "durationFrames": 150},
         \(baseBlock)}
        """
        let root = try writeTempJSON(json)
        XCTAssertThrowsError(try TemplateFixtureReader.read(catalogID: "strict_case", root: root)) {
            XCTAssertEqual($0 as? TemplateFixtureReader.ReadError, .wrongType(field: "width"))
        }
    }

    func testNumberAsStringRejected() throws {
        // sceneId as a number must be rejected.
        let json = """
        {"sceneId": 5, "canvas": {"width": 1080, "height": 1920, "fps": 30, "durationFrames": 150},
         \(baseBlock)}
        """
        let root = try writeTempJSON(json)
        XCTAssertThrowsError(try TemplateFixtureReader.read(catalogID: "strict_case", root: root)) {
            XCTAssertEqual($0 as? TemplateFixtureReader.ReadError, .wrongType(field: "sceneId"))
        }
    }

    func testAuthoringBindingSlotsResolveOnlyThroughExplicitFakeBindings() throws {
        let descriptor = try TemplateFixtureReader.read(catalogID: "full_image", root: repositoryRoot())
        XCTAssertEqual(descriptor.slots.first?.bindingKey, "media")
        let payload = try CanonicalProjectFixtures.instantiate(
            descriptor, sceneInstanceID: "fi.inst", payloadID: "fi.pl", selection: defaultSelection(descriptor)
        )
        guard case .video(let binding) = payload.layers.first?.content else { return XCTFail("expected video") }
        XCTAssertTrue(binding.media.raw.contains("fake-media"))
    }
}
