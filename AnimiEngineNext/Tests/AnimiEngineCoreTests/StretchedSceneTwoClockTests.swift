import XCTest
@testable import AnimiEngineCore
import AnimiEngineTestSupport

/// CP7.5: canonical two-clock support for STRETCHED scenes (timelineSpan > nominalDuration).
///
/// Contract under test:
///  - the VISUAL/template clock (`visualPlaybackTime`) HOLDS at `nominalDuration - 1 tick` past the
///    native end;
///  - the MEDIA/video clock (`mediaPlaybackTime`) CONTINUES across the full timeline span;
///  - `projectDuration` and scene/transition boundaries use the timeline span;
///  - a frame in the stretched tail evaluates (no `evaluate.outsideProject`).
final class StretchedSceneTwoClockTests: XCTestCase {

    // Native 5s @30fps == 150 frames; ticks/frame = 240000/30 = 8000 → nominal 1_200_000 ticks.
    // Stretched to 10s == 2_400_000 ticks.
    private let nominal: Int64 = 1_200_000
    private let span: Int64 = 2_400_000

    private func stretchedDoc() throws -> CanonicalProjectDocument {
        let scene = try CanonicalProjectFixtures.scene(
            withVideoLayers: 1, sceneID: "s", payloadID: "p", durationTicks: nominal)
        return try CanonicalProjectFixtures.singleSceneDocument(
            payload: scene, nominalDurationTicks: nominal, timelineSpanTicks: span)
    }

    func test_projectDuration_usesTimelineSpan() throws {
        let doc = try stretchedDoc()
        XCTAssertEqual(try doc.manifest.projectDuration().ticks, span,
                       "projectDuration sums timelineSpan, not nominalDuration")
    }

    func test_withinNativeSpan_bothClocksEqual() throws {
        // tick 600_000 (2.5s) is within the native 5s → visual == media.
        let plan = try EvaluationHarness.evaluate(try stretchedDoc(), atTick: 600_000)
        guard case .single(let s) = plan.body else { return XCTFail("expected single") }
        XCTAssertEqual(s.visualPlaybackTime.ticks, 600_000)
        XCTAssertEqual(s.mediaPlaybackTime.ticks, 600_000)
    }

    func test_inStretchedTail_visualHolds_mediaContinues() throws {
        // tick 1_800_000 (7.5s) is PAST the native 5s end (1_200_000), inside the 10s span.
        let plan = try EvaluationHarness.evaluate(try stretchedDoc(), atTick: 1_800_000)
        guard case .single(let s) = plan.body else { return XCTFail("expected single") }
        // VISUAL holds at nominal-1 tick.
        XCTAssertEqual(s.visualPlaybackTime.ticks, nominal - 1, "visual holds at last native tick")
        // MEDIA continues to the real scene-local time.
        XCTAssertEqual(s.mediaPlaybackTime.ticks, 1_800_000, "media continues across the stretched span")
    }

    func test_lastFrameOfSpan_evaluates_noOutsideProject() throws {
        // The last representable tick (span - 1) must evaluate without throwing outsideProject.
        let plan = try EvaluationHarness.evaluate(try stretchedDoc(), atTick: span - 1)
        guard case .single(let s) = plan.body else { return XCTFail("expected single") }
        XCTAssertEqual(s.visualPlaybackTime.ticks, nominal - 1)
        XCTAssertEqual(s.mediaPlaybackTime.ticks, span - 1)
    }

    func test_videoTarget_continuesPastNativeEnd() throws {
        // The video SourceRequest target must reflect the MEDIA clock — a later target in the tail.
        let mid = try EvaluationHarness.evaluate(try stretchedDoc(), atTick: 600_000)   // within native
        let tail = try EvaluationHarness.evaluate(try stretchedDoc(), atTick: 1_800_000) // stretched tail
        guard case .single(let sMid) = mid.body, case .video(let reqMid) = sMid.layers.first?.content,
              case .single(let sTail) = tail.body, case .video(let reqTail) = sTail.layers.first?.content else {
            return XCTFail("expected video layers")
        }
        // Targets are RationalSourceTime; tail target (7.5s) must exceed mid target (2.5s).
        let midSec = Double(reqMid.target.numerator) / Double(reqMid.target.denominator)
        let tailSec = Double(reqTail.target.numerator) / Double(reqTail.target.denominator)
        XCTAssertGreaterThan(tailSec, midSec, "video target continues past native end (media clock)")
        XCTAssertEqual(tailSec, 7.5, accuracy: 0.001, "media clock = scene-local seconds")
    }

    func test_videoLayer_stillVisibleInStretchedTail() throws {
        // The layer (authored activeRange [0, nominal)) must still render in the tail because the
        // VISUAL clock (which drives activeRange filtering) holds at nominal-1 (inside the range).
        let plan = try EvaluationHarness.evaluate(try stretchedDoc(), atTick: 1_800_000)
        guard case .single(let s) = plan.body else { return XCTFail("expected single") }
        XCTAssertEqual(s.layers.count, 1, "layer held-visible across the stretched tail")
    }

    func test_unstretched_unchanged() throws {
        // timelineSpan defaulting to nominal → identical to pre-CP7.5 behavior.
        let scene = try CanonicalProjectFixtures.scene(withVideoLayers: 1, sceneID: "s", payloadID: "p", durationTicks: nominal)
        let doc = try CanonicalProjectFixtures.singleSceneDocument(payload: scene, nominalDurationTicks: nominal)
        XCTAssertEqual(try doc.manifest.projectDuration().ticks, nominal)
        let plan = try EvaluationHarness.evaluate(doc, atTick: 600_000)
        guard case .single(let s) = plan.body else { return XCTFail("expected single") }
        XCTAssertEqual(s.visualPlaybackTime.ticks, 600_000)
        XCTAssertEqual(s.mediaPlaybackTime.ticks, 600_000)
        // A tick at nominal must now be outside the project (unstretched span == nominal).
        XCTAssertThrowsError(try EvaluationHarness.evaluate(doc, atTick: nominal))
    }

    func test_stretchedOutgoing_transition_boundaryBySpan_visualClamp_mediaContinues() throws {
        // Scene A: native 5s (1_200_000), STRETCHED to 10s (2_400_000). Scene B: native 5s.
        // A fade transition (1s = 240_000) sits at the boundary = A's STRETCHED end (2_400_000).
        let a = try CanonicalProjectFixtures.scene(withVideoLayers: 1, sceneID: "a", payloadID: "pa", durationTicks: nominal)
        let b = try CanonicalProjectFixtures.scene(withVideoLayers: 1, sceneID: "b", payloadID: "pb", durationTicks: nominal)
        let transitionDur: Int64 = 240_000
        let entryA = SceneManifestEntry(
            id: a.sceneID, payloadID: a.payloadID,
            nominalDuration: try TickDuration(ticks: nominal),
            postRollCapability: try TickDuration(ticks: transitionDur / 2),
            timelineSpan: try TickDuration(ticks: span))
        let entryB = SceneManifestEntry(
            id: b.sceneID, payloadID: b.payloadID,
            nominalDuration: try TickDuration(ticks: nominal),
            postRollCapability: try TickDuration(ticks: transitionDur / 2))
        let manifest = CanonicalProjectManifest(
            schemaVersion: CanonicalProjectManifest.supportedSchemaVersion,
            output: try CanonicalProjectFixtures.output(),
            scenes: [entryA, entryB],
            boundaryTransitions: [try CanonicalProjectFixtures.fadeTransition(durationTicks: transitionDur)],
            overlays: [])
        let doc = CanonicalProjectDocument(manifest: manifest, scenePayloads: [a, b], overlayPayloads: [])

        // projectDuration = span(A) + nominal(B) = 2_400_000 + 1_200_000 = 3_600_000.
        XCTAssertEqual(try doc.manifest.projectDuration().ticks, span + nominal)

        // Boundary is at A's STRETCHED end (2_400_000). Evaluate just before it, inside the window.
        // Window = [boundary - 120_000, boundary + 120_000). Pick boundary - 8000.
        let boundary: Int64 = span
        let plan = try EvaluationHarness.evaluate(doc, atTick: boundary - 8_000)
        guard case .transition(let t) = plan.body else { return XCTFail("expected transition at span boundary") }
        // Outgoing A: MEDIA continues to ~span (well past nominal); VISUAL holds at nominal-1.
        XCTAssertEqual(t.outgoing.mediaPlaybackTime.ticks, boundary - 8_000, "outgoing media continues to the stretched boundary")
        XCTAssertEqual(t.outgoing.visualPlaybackTime.ticks, nominal - 1, "outgoing visual held at last native tick during transition")
    }

    func test_materialAvailability_animationByVisual_videoByMedia() throws {
        // A stretched scene whose video trim covers the WHOLE span, and whose template animation is
        // authored only to the NATIVE end with `.becomeInactive`. This must VALIDATE:
        //  - video material checked across the MEDIA span (trim 600s covers it) → ok;
        //  - `.becomeInactive` animation checked only across the VISUAL (native) span → ok
        //    (the held tail past nominal imposes no animation requirement).
        let layer = try CanonicalProjectFixtures.videoLayer(
            id: "s.l0", zIndex: 0, stableOrdinal: 0, sceneDurationTicks: nominal,
            media: "m", trimSeconds: 600,
            placement: try CanonicalProjectFixtures.placement(x: 0, y: 0, width: 100, height: 100),
            animation: try AnimationReference(
                variantID: "v1", animationRef: "v1.json",
                authoredDuration: try TickDuration(ticks: nominal),
                ifShorter: .becomeInactive, ifLonger: .cutAtEvaluationEnd))
        let scene = ResolvedScenePayload(
            payloadID: try ScenePayloadID("p"), sceneID: try SceneInstanceID("s"),
            templateRef: try TemplateReference(catalogID: "c", sceneID: "s"), layers: [layer])
        let doc = try CanonicalProjectFixtures.singleSceneDocument(
            payload: scene, nominalDurationTicks: nominal, timelineSpanTicks: span)
        // Must NOT throw: animation availability is visual-bounded; video is media-bounded.
        XCTAssertNoThrow(try ProjectValidator.validate(doc))
        // And it evaluates across the stretched tail.
        XCTAssertNoThrow(try EvaluationHarness.evaluate(doc, atTick: span - 1))
    }

    func test_invalidTimelineSpan_belowNominal_rejected() throws {
        // timelineSpan < nominalDuration must fail validation.
        let scene = try CanonicalProjectFixtures.scene(withVideoLayers: 1, sceneID: "s", payloadID: "p", durationTicks: nominal)
        let entry = SceneManifestEntry(
            id: scene.sceneID, payloadID: scene.payloadID,
            nominalDuration: try TickDuration(ticks: nominal), postRollCapability: .zero,
            timelineSpan: try TickDuration(ticks: nominal - 1))
        let manifest = CanonicalProjectManifest(
            schemaVersion: CanonicalProjectManifest.supportedSchemaVersion,
            output: try CanonicalProjectFixtures.output(), scenes: [entry],
            boundaryTransitions: [], overlays: [])
        let doc = CanonicalProjectDocument(manifest: manifest, scenePayloads: [scene], overlayPayloads: [])
        XCTAssertThrowsError(try ProjectValidator.validate(doc)) {
            XCTAssertEqual($0 as? ProjectValidationError, .invalidTimelineSpan(scene: "s"))
        }
    }
}
