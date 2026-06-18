import XCTest
@testable import AnimiEngineCore
import AnimiEngineTestSupport

/// Semantic project-validation tests (Task-002 plan, §15.3, §18).
final class ProjectValidationTests: XCTestCase {

    private func scene(_ id: String, _ payload: String, layers: Int = 1, ticks: Int64 = 240_000) throws -> ResolvedScenePayload {
        try CanonicalProjectFixtures.scene(withVideoLayers: layers, sceneID: id, payloadID: payload, durationTicks: ticks)
    }

    func testEmptyProjectRejected() throws {
        let manifest = CanonicalProjectManifest(
            schemaVersion: 1, output: try CanonicalProjectFixtures.output(),
            scenes: [], boundaryTransitions: [], overlays: []
        )
        let doc = CanonicalProjectDocument(manifest: manifest, scenePayloads: [], overlayPayloads: [])
        XCTAssertThrowsError(try ProjectValidator.validate(doc)) {
            XCTAssertEqual($0 as? ProjectValidationError, .emptyProject)
        }
    }

    func testTransitionCountMismatchRejected() throws {
        let a = try scene("a", "pa")
        let manifest = CanonicalProjectManifest(
            schemaVersion: 1, output: try CanonicalProjectFixtures.output(),
            scenes: [SceneManifestEntry(id: a.sceneID, payloadID: a.payloadID, nominalDuration: try TickDuration(ticks: 240_000), postRollCapability: .zero)],
            boundaryTransitions: [try CanonicalProjectFixtures.cutTransition()],  // 1 boundary for 1 scene → mismatch
            overlays: []
        )
        let doc = CanonicalProjectDocument(manifest: manifest, scenePayloads: [a], overlayPayloads: [])
        XCTAssertThrowsError(try ProjectValidator.validate(doc)) {
            XCTAssertEqual($0 as? ProjectValidationError, .transitionCountMismatch(expected: 0, actual: 1))
        }
    }

    func testCutWithNonZeroDurationRejected() throws {
        let a = try scene("a", "pa"); let b = try scene("b", "pb")
        let badCut = SceneTransition(kind: .cut, duration: try TickDuration(ticks: 1), easing: try EasingReference("none"))
        let doc = try CanonicalProjectFixtures.twoSceneDocument(
            sceneA: a, sceneB: b, durationATicks: 240_000, durationBTicks: 240_000,
            transition: badCut, postRollTicks: 0
        )
        XCTAssertThrowsError(try ProjectValidator.validate(doc)) {
            XCTAssertEqual($0 as? ProjectValidationError, .cutWithNonZeroDuration)
        }
    }

    func testAnimatedEffectWithZeroDurationRejected() throws {
        let a = try scene("a", "pa"); let b = try scene("b", "pb")
        let badAnim = SceneTransition(
            kind: .animated(TransitionEffect(effectID: try TransitionEffectID("fade"), parameters: .empty)),
            duration: .zero, easing: try EasingReference("linear")
        )
        let doc = try CanonicalProjectFixtures.twoSceneDocument(
            sceneA: a, sceneB: b, durationATicks: 240_000, durationBTicks: 240_000,
            transition: badAnim, postRollTicks: 0
        )
        XCTAssertThrowsError(try ProjectValidator.validate(doc)) {
            XCTAssertEqual($0 as? ProjectValidationError, .animatedEffectWithZeroDuration)
        }
    }

    func testDuplicateStableOrdinalRejected() throws {
        let l0 = try CanonicalProjectFixtures.videoLayer(id: "x", zIndex: 0, stableOrdinal: 5, sceneDurationTicks: 240_000, media: "m", trimSeconds: 600, placement: try CanonicalProjectFixtures.placement(x: 0, y: 0, width: 10, height: 10))
        let l1 = try CanonicalProjectFixtures.videoLayer(id: "y", zIndex: 1, stableOrdinal: 5, sceneDurationTicks: 240_000, media: "m", trimSeconds: 600, placement: try CanonicalProjectFixtures.placement(x: 0, y: 0, width: 10, height: 10))
        let payload = ResolvedScenePayload(payloadID: try ScenePayloadID("p"), sceneID: try SceneInstanceID("s"), templateRef: try TemplateReference(catalogID: "c", sceneID: "s"), layers: [l0, l1])
        let doc = try CanonicalProjectFixtures.singleSceneDocument(payload: payload, nominalDurationTicks: 240_000)
        XCTAssertThrowsError(try ProjectValidator.validate(doc)) {
            XCTAssertEqual($0 as? ProjectValidationError, .duplicateStableOrdinal(scope: "layer[p]", ordinal: 5))
        }
    }

    func testOverlayOutsideProjectRejected() throws {
        let a = try scene("a", "pa")
        let overlayID = try OverlayID("o"); let payloadID = try OverlayPayloadID("op")
        // Overlay range extends past project end (240000).
        let entry = OverlayManifestEntry(
            id: overlayID, payloadID: payloadID,
            timeRange: try ProjectTimeRange(start: .zero, end: try ProjectTime(ticks: 300_000)),
            zIndex: 0, stableOrdinal: 0
        )
        let overlayPayload = ResolvedOverlayPayload(
            payloadID: payloadID, overlayID: overlayID, content: .text(try TextContentReference("t")),
            placement: try CanonicalProjectFixtures.placement(x: 0, y: 0, width: 10, height: 10), animation: nil
        )
        let manifest = CanonicalProjectManifest(
            schemaVersion: 1, output: try CanonicalProjectFixtures.output(),
            scenes: [SceneManifestEntry(id: a.sceneID, payloadID: a.payloadID, nominalDuration: try TickDuration(ticks: 240_000), postRollCapability: .zero)],
            boundaryTransitions: [], overlays: [entry]
        )
        let doc = CanonicalProjectDocument(manifest: manifest, scenePayloads: [a], overlayPayloads: [overlayPayload])
        XCTAssertThrowsError(try ProjectValidator.validate(doc)) {
            XCTAssertEqual($0 as? ProjectValidationError, .overlayOutsideProject(overlay: "o"))
        }
    }

    func testMissingAndUnexpectedPayloadRejected() throws {
        let a = try scene("a", "pa")
        // Manifest references payload "pa" but supply a different payload id.
        let wrong = try scene("a", "wrong")
        let manifest = CanonicalProjectManifest(
            schemaVersion: 1, output: try CanonicalProjectFixtures.output(),
            scenes: [SceneManifestEntry(id: a.sceneID, payloadID: a.payloadID, nominalDuration: try TickDuration(ticks: 240_000), postRollCapability: .zero)],
            boundaryTransitions: [], overlays: []
        )
        let doc = CanonicalProjectDocument(manifest: manifest, scenePayloads: [wrong], overlayPayloads: [])
        XCTAssertThrowsError(try ProjectValidator.validate(doc)) {
            XCTAssertEqual($0 as? ProjectValidationError, .missingPayload(kind: "scene", id: "pa"))
        }
    }

    func testInconsistentPayloadSceneIDRejected() throws {
        // Manifest scene id "a" but payload declares sceneID "other".
        let payload = ResolvedScenePayload(
            payloadID: try ScenePayloadID("pa"), sceneID: try SceneInstanceID("other"),
            templateRef: try TemplateReference(catalogID: "c", sceneID: "s"),
            layers: [try CanonicalProjectFixtures.imageLayer(id: "l", zIndex: 0, stableOrdinal: 0, sceneDurationTicks: 240_000, image: "img", placement: try CanonicalProjectFixtures.placement(x: 0, y: 0, width: 10, height: 10))]
        )
        let manifest = CanonicalProjectManifest(
            schemaVersion: 1, output: try CanonicalProjectFixtures.output(),
            scenes: [SceneManifestEntry(id: try SceneInstanceID("a"), payloadID: try ScenePayloadID("pa"), nominalDuration: try TickDuration(ticks: 240_000), postRollCapability: .zero)],
            boundaryTransitions: [], overlays: []
        )
        let doc = CanonicalProjectDocument(manifest: manifest, scenePayloads: [payload], overlayPayloads: [])
        XCTAssertThrowsError(try ProjectValidator.validate(doc)) {
            XCTAssertEqual($0 as? ProjectValidationError, .inconsistentPayload(kind: "scene", id: "pa"))
        }
    }

    func testValidSingleSceneProjectPasses() throws {
        let a = try scene("a", "pa")
        let doc = try CanonicalProjectFixtures.singleSceneDocument(payload: a, nominalDurationTicks: 240_000)
        XCTAssertNoThrow(try ProjectValidator.validate(doc))
    }

    // MARK: - C-5: schema version

    func testUnsupportedSchemaVersionRejected() throws {
        let a = try scene("a", "pa")
        let manifest = CanonicalProjectManifest(
            schemaVersion: 2, output: try CanonicalProjectFixtures.output(),
            scenes: [SceneManifestEntry(id: a.sceneID, payloadID: a.payloadID, nominalDuration: try TickDuration(ticks: 240_000), postRollCapability: .zero)],
            boundaryTransitions: [], overlays: []
        )
        let doc = CanonicalProjectDocument(manifest: manifest, scenePayloads: [a], overlayPayloads: [])
        XCTAssertThrowsError(try ProjectValidator.validate(doc)) {
            XCTAssertEqual($0 as? ProjectValidationError, .unsupportedSchemaVersion(found: 2, supported: 1))
        }
        // TimelineIndex must also reject the invalid manifest.
        XCTAssertThrowsError(try TimelineIndex(manifest: manifest)) {
            XCTAssertEqual($0 as? ProjectValidationError, .unsupportedSchemaVersion(found: 2, supported: 1))
        }
    }

    // MARK: - C-1: full-document material validation (scenes + overlays)

    /// A scene whose single video layer is active over `[0, sceneTicks)` but trims only `trimSeconds`.
    private func videoScene(id: String, payload: String, sceneTicks: Int64, trimSeconds: Int64) throws -> ResolvedScenePayload {
        let layer = try CanonicalProjectFixtures.videoLayer(
            id: "\(id).v", zIndex: 0, stableOrdinal: 0, sceneDurationTicks: sceneTicks,
            media: "m-\(id)", trimSeconds: trimSeconds,
            placement: try CanonicalProjectFixtures.placement(x: 0, y: 0, width: 100, height: 100)
        )
        return ResolvedScenePayload(
            payloadID: try ScenePayloadID(payload), sceneID: try SceneInstanceID(id),
            templateRef: try TemplateReference(catalogID: "c", sceneID: id), layers: [layer]
        )
    }

    func testInsufficientNormalPlaybackVideoMaterialRejectedAtValidation() throws {
        // Active range [0, 240000) ⇒ needs ~1s of source, but trim is 0.0001s (1 native unit). The
        // layer's last requested target leaves the trim range ⇒ rejected at validate/decodeValidated.
        let layer = SceneLayer(
            id: try LayerID("v"), zIndex: 0, stableOrdinal: 0,
            activeRange: try ScenePlaybackRange(start: .zero, end: try ScenePlaybackTime(ticks: 240_000)),
            placement: try CanonicalProjectFixtures.placement(x: 0, y: 0, width: 10, height: 10),
            mediaPlacement: try CanonicalProjectFixtures.mediaPlacement(),
            content: .video(VideoBinding(
                media: try MediaReference("m"),
                sourceMapping: SourceTimeMapping(
                    trimRange: try RationalSourceRange(start: .zero, end: try RationalSourceTime(numerator: 1, denominator: 240_000)),
                    nativeTimescale: try SourceTimescale(unitsPerSecond: 30_000), rate: .oneToOne
                )
            )), animation: nil
        )
        let payload = ResolvedScenePayload(payloadID: try ScenePayloadID("pa"), sceneID: try SceneInstanceID("a"), templateRef: try TemplateReference(catalogID: "c", sceneID: "a"), layers: [layer])
        let doc = try CanonicalProjectFixtures.singleSceneDocument(payload: payload, nominalDurationTicks: 240_000)
        XCTAssertThrowsError(try ProjectValidator.validate(doc)) { error in
            guard case .insufficientVideoMaterial = error as? ProjectValidationError else {
                return XCTFail("expected insufficientVideoMaterial, got \(error)")
            }
        }
        // `encode` now validates first (C-5), so it also rejects this invalid document — proving the
        // full-document material gate fires on the persistence path too.
        XCTAssertThrowsError(try CanonicalProjectEncoding.encode(doc)) { error in
            guard case .insufficientVideoMaterial = error as? ProjectValidationError else {
                return XCTFail("expected insufficientVideoMaterial on encode, got \(error)")
            }
        }
    }

    func testOverlayBecomeInactiveOutlivingAnimationRejectedAtValidation() throws {
        let a = try scene("a", "pa")
        let overlayID = try OverlayID("o"); let overlayPayloadID = try OverlayPayloadID("op")
        let range = try ProjectTimeRange(start: .zero, end: try ProjectTime(ticks: 240_000))
        let entry = OverlayManifestEntry(id: overlayID, payloadID: overlayPayloadID, timeRange: range, zIndex: 0, stableOrdinal: 0)
        let anim = try AnimationReference(variantID: "v", animationRef: "v.json", authoredDuration: try TickDuration(ticks: 1), ifShorter: .becomeInactive, ifLonger: .cutAtEvaluationEnd)
        let overlayPayload = ResolvedOverlayPayload(payloadID: overlayPayloadID, overlayID: overlayID, content: .text(try TextContentReference("t")), placement: try CanonicalProjectFixtures.placement(x: 0, y: 0, width: 10, height: 10), animation: anim)
        let manifest = CanonicalProjectManifest(
            schemaVersion: 1, output: try CanonicalProjectFixtures.output(),
            scenes: [SceneManifestEntry(id: a.sceneID, payloadID: a.payloadID, nominalDuration: try TickDuration(ticks: 240_000), postRollCapability: .zero)],
            boundaryTransitions: [], overlays: [entry]
        )
        let doc = CanonicalProjectDocument(manifest: manifest, scenePayloads: [a], overlayPayloads: [overlayPayload])
        XCTAssertThrowsError(try ProjectValidator.validate(doc)) {
            XCTAssertEqual($0 as? ProjectValidationError, .unavailableAnimationContinuation(layer: "o"))
        }
    }

    func testOverlayHoldLastAndLoopAreValidContinuations() throws {
        for policy in [AnimationShorterPolicy.holdLast, .loop] {
            let a = try scene("a", "pa")
            let overlayID = try OverlayID("o"); let overlayPayloadID = try OverlayPayloadID("op")
            let range = try ProjectTimeRange(start: .zero, end: try ProjectTime(ticks: 240_000))
            let entry = OverlayManifestEntry(id: overlayID, payloadID: overlayPayloadID, timeRange: range, zIndex: 0, stableOrdinal: 0)
            // authoredDuration 1 < overlayDuration 240000, but holdLast/loop are valid continuations.
            let anim = try AnimationReference(variantID: "v", animationRef: "v.json", authoredDuration: try TickDuration(ticks: 1), ifShorter: policy, ifLonger: .cutAtEvaluationEnd)
            let overlayPayload = ResolvedOverlayPayload(payloadID: overlayPayloadID, overlayID: overlayID, content: .text(try TextContentReference("t")), placement: try CanonicalProjectFixtures.placement(x: 0, y: 0, width: 10, height: 10), animation: anim)
            let manifest = CanonicalProjectManifest(
                schemaVersion: 1, output: try CanonicalProjectFixtures.output(),
                scenes: [SceneManifestEntry(id: a.sceneID, payloadID: a.payloadID, nominalDuration: try TickDuration(ticks: 240_000), postRollCapability: .zero)],
                boundaryTransitions: [], overlays: [entry]
            )
            let doc = CanonicalProjectDocument(manifest: manifest, scenePayloads: [a], overlayPayloads: [overlayPayload])
            XCTAssertNoThrow(try ProjectValidator.validate(doc), "policy \(policy)")
        }
    }

    func testValidProjectPassesAndEvaluatorNeverThrowsMaterialError() throws {
        let a = try videoScene(id: "a", payload: "pa", sceneTicks: 240_000, trimSeconds: 600)
        let doc = try CanonicalProjectFixtures.singleSceneDocument(payload: a, nominalDurationTicks: 240_000)
        try ProjectValidator.validate(doc)
        let window = try EvaluationHarness.wholeProjectWindow(doc)
        for tick in stride(from: Int64(0), to: 240_000, by: 8_000) {
            XCTAssertNoThrow(try TimelineEvaluator.evaluate(window, at: try ProjectTime(ticks: tick)))
        }
    }

    // MARK: - C-1: documented path guarantees

    func testFullDocumentPathRejectsBeforeIndexCreation() throws {
        // Invalid material ⇒ decodeValidated/validate throws; we never construct a TimelineIndex here.
        let layer = SceneLayer(
            id: try LayerID("v"), zIndex: 0, stableOrdinal: 0,
            activeRange: try ScenePlaybackRange(start: .zero, end: try ScenePlaybackTime(ticks: 240_000)),
            placement: try CanonicalProjectFixtures.placement(x: 0, y: 0, width: 10, height: 10),
            mediaPlacement: try CanonicalProjectFixtures.mediaPlacement(),
            content: .video(VideoBinding(media: try MediaReference("m"), sourceMapping: SourceTimeMapping(
                trimRange: try RationalSourceRange(start: .zero, end: try RationalSourceTime(numerator: 1, denominator: 240_000)),
                nativeTimescale: try SourceTimescale(unitsPerSecond: 30_000), rate: .oneToOne))), animation: nil
        )
        let payload = ResolvedScenePayload(payloadID: try ScenePayloadID("pa"), sceneID: try SceneInstanceID("a"), templateRef: try TemplateReference(catalogID: "c", sceneID: "a"), layers: [layer])
        let doc = try CanonicalProjectFixtures.singleSceneDocument(payload: payload, nominalDurationTicks: 240_000)
        XCTAssertThrowsError(try ProjectValidator.validate(doc))
    }
}
