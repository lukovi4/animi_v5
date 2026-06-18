import XCTest
@testable import AnimiEngineCore
import AnimiEngineTestSupport

/// Evaluation-window builder validation tests (Task-002 plan §10.3; corrective plan C-1, C-4).
final class EvaluationWindowBuilderTests: XCTestCase {

    private func setup() throws -> (TimelineIndex, CanonicalProjectDocument) {
        let a = try CanonicalProjectFixtures.scene(withVideoLayers: 2, sceneID: "a", payloadID: "pa", durationTicks: 240_000)
        let doc = try CanonicalProjectFixtures.singleSceneDocument(payload: a, nominalDurationTicks: 240_000)
        let index = try TimelineIndex(manifest: doc.manifest)
        return (index, doc)
    }

    private func fullCoverageRequirement(_ index: TimelineIndex, _ doc: CanonicalProjectDocument) throws -> EvaluationWindowRequirement {
        let coverage = try ProjectTimeRange(start: .zero, end: try ProjectTime(ticks: doc.manifest.projectDuration().ticks))
        return try index.requirements(for: coverage)
    }

    func testBuildsValidWindow() throws {
        let (index, doc) = try setup()
        let req = try fullCoverageRequirement(index, doc)
        let window = try EvaluationWindowBuilder.build(
            requirement: req, scenes: doc.scenePayloads, overlays: doc.overlayPayloads
        )
        XCTAssertEqual(window.scenes.count, 1)
        XCTAssertEqual(window.scenes.first?.span.payloadID.raw, "pa")
    }

    func testBuilderUsesRequirementOutputAndDuration() throws {
        let (index, doc) = try setup()
        let req = try fullCoverageRequirement(index, doc)
        let window = try EvaluationWindowBuilder.build(requirement: req, scenes: doc.scenePayloads, overlays: doc.overlayPayloads)
        // Derived from the requirement (which is derived from the index) — no caller override exists.
        XCTAssertEqual(window.output, index.output)
        XCTAssertEqual(window.projectDuration, index.projectDuration)
        XCTAssertEqual(window.output, req.output)
        XCTAssertEqual(window.projectDuration, req.projectDuration)
    }

    func testRejectsMissingPayload() throws {
        let (index, doc) = try setup()
        let req = try fullCoverageRequirement(index, doc)
        XCTAssertThrowsError(try EvaluationWindowBuilder.build(requirement: req, scenes: [], overlays: [])) {
            XCTAssertEqual($0 as? ProjectValidationError, .missingPayload(kind: "scene", id: "pa"))
        }
    }

    func testRejectsUnexpectedPayload() throws {
        let (index, doc) = try setup()
        let req = try fullCoverageRequirement(index, doc)
        let extra = try CanonicalProjectFixtures.scene(withVideoLayers: 1, sceneID: "extra", payloadID: "extraP", durationTicks: 240_000)
        XCTAssertThrowsError(try EvaluationWindowBuilder.build(requirement: req, scenes: doc.scenePayloads + [extra], overlays: [])) {
            XCTAssertEqual($0 as? ProjectValidationError, .unexpectedPayload(kind: "scene", id: "extraP"))
        }
    }

    func testRejectsDuplicatePayload() throws {
        let (index, doc) = try setup()
        let req = try fullCoverageRequirement(index, doc)
        XCTAssertThrowsError(try EvaluationWindowBuilder.build(requirement: req, scenes: doc.scenePayloads + doc.scenePayloads, overlays: [])) {
            XCTAssertEqual($0 as? ProjectValidationError, .duplicatePayload(kind: "scene", id: "pa"))
        }
    }

    // MARK: - Lazy-path material validation (matching-ID / different-content)

    /// A scene payload whose video layer is active over `[0, sceneTicks)` but trims only `trimSeconds`.
    private func scene(id: String, payload: String, sceneTicks: Int64, trimSeconds: Int64) throws -> ResolvedScenePayload {
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

    func testBuilderRejectsLoadedPayloadWithMatchingIDButInsufficientMaterial() throws {
        // Manifest scene declares 240000-tick body; the loaded payload has the same id but a 0.0001s
        // trim (far too short to cover its active range), so the builder must reject it.
        let declared = try scene(id: "a", payload: "pa", sceneTicks: 240_000, trimSeconds: 600)
        let doc = try CanonicalProjectFixtures.singleSceneDocument(payload: declared, nominalDurationTicks: 240_000)
        let index = try TimelineIndex(manifest: doc.manifest)
        let req = try fullCoverageRequirement(index, doc)
        // Same id, insufficient trim (1 tick of source ⇒ targets quickly exit the trim range).
        let tampered = ResolvedScenePayload(
            payloadID: try ScenePayloadID("pa"), sceneID: try SceneInstanceID("a"),
            templateRef: try TemplateReference(catalogID: "c", sceneID: "a"),
            layers: [try shortTrimVideoLayer(id: "a.v", sceneTicks: 240_000)]
        )
        XCTAssertThrowsError(try EvaluationWindowBuilder.build(requirement: req, scenes: [tampered], overlays: [])) { error in
            guard case .insufficientVideoMaterial = error as? ProjectValidationError else {
                return XCTFail("expected insufficientVideoMaterial, got \(error)")
            }
        }
    }

    private func shortTrimVideoLayer(id: String, sceneTicks: Int64) throws -> SceneLayer {
        // Trim [0, 1/240000) seconds — only the first tick is in range, so later ticks fail.
        let mapping = SourceTimeMapping(
            trimRange: try RationalSourceRange(
                start: .zero, end: try RationalSourceTime(numerator: 1, denominator: 240_000)
            ),
            nativeTimescale: try SourceTimescale(unitsPerSecond: 30_000), rate: .oneToOne
        )
        let range = try ScenePlaybackRange(start: .zero, end: try ScenePlaybackTime(ticks: sceneTicks))
        return SceneLayer(
            id: try LayerID(id), zIndex: 0, stableOrdinal: 0, activeRange: range,
            placement: try CanonicalProjectFixtures.placement(x: 0, y: 0, width: 100, height: 100),
            mediaPlacement: try CanonicalProjectFixtures.mediaPlacement(),
            content: .video(VideoBinding(media: try MediaReference("m"), sourceMapping: mapping)),
            animation: nil
        )
    }

    func testBuilderRejectsLoadedOverlayWithMatchingIDButInsufficientAnimation() throws {
        // Manifest overlay declares an animation that covers its interval; the loaded overlay payload
        // (same ids) carries a `.becomeInactive` animation too short to cover the active interval.
        let scenePayload = try CanonicalProjectFixtures.scene(withVideoLayers: 1, sceneID: "s", payloadID: "p", durationTicks: 240_000)
        let overlayID = try OverlayID("o"); let overlayPayloadID = try OverlayPayloadID("op")
        let range = try ProjectTimeRange(start: .zero, end: try ProjectTime(ticks: 240_000))
        let entry = OverlayManifestEntry(id: overlayID, payloadID: overlayPayloadID, timeRange: range, zIndex: 0, stableOrdinal: 0)
        let manifest = CanonicalProjectManifest(
            schemaVersion: 1, output: try CanonicalProjectFixtures.output(),
            scenes: [SceneManifestEntry(id: scenePayload.sceneID, payloadID: scenePayload.payloadID, nominalDuration: try TickDuration(ticks: 240_000), postRollCapability: .zero)],
            boundaryTransitions: [], overlays: [entry]
        )
        let index = try TimelineIndex(manifest: manifest)
        let req = try index.requirements(for: try ProjectTimeRange(start: .zero, end: try ProjectTime(ticks: 240_000)))
        // Tampered overlay payload: becomeInactive with authoredDuration 1 < overlayDuration 240000.
        let shortAnim = try AnimationReference(
            variantID: "v", animationRef: "v.json", authoredDuration: try TickDuration(ticks: 1),
            ifShorter: .becomeInactive, ifLonger: .cutAtEvaluationEnd
        )
        let tamperedOverlay = ResolvedOverlayPayload(
            payloadID: overlayPayloadID, overlayID: overlayID, content: .text(try TextContentReference("t")),
            placement: try CanonicalProjectFixtures.placement(x: 0, y: 0, width: 10, height: 10), animation: shortAnim
        )
        XCTAssertThrowsError(try EvaluationWindowBuilder.build(requirement: req, scenes: [scenePayload], overlays: [tamperedOverlay])) { error in
            guard case .unavailableAnimationContinuation = error as? ProjectValidationError else {
                return XCTFail("expected unavailableAnimationContinuation, got \(error)")
            }
        }
    }

    func testBuilderAcceptsValidLoadedPayloadsIncludingOverlays() throws {
        let scenePayload = try CanonicalProjectFixtures.scene(withVideoLayers: 1, sceneID: "s", payloadID: "p", durationTicks: 240_000)
        let overlays = try CanonicalProjectFixtures.textOverlays(count: 2, projectDurationTicks: 240_000)
        let manifest = CanonicalProjectManifest(
            schemaVersion: 1, output: try CanonicalProjectFixtures.output(),
            scenes: [SceneManifestEntry(id: scenePayload.sceneID, payloadID: scenePayload.payloadID, nominalDuration: try TickDuration(ticks: 240_000), postRollCapability: .zero)],
            boundaryTransitions: [], overlays: overlays.map(\.0)
        )
        let index = try TimelineIndex(manifest: manifest)
        let req = try index.requirements(for: try ProjectTimeRange(start: .zero, end: try ProjectTime(ticks: 240_000)))
        let window = try EvaluationWindowBuilder.build(requirement: req, scenes: [scenePayload], overlays: overlays.map(\.1))
        XCTAssertEqual(window.scenes.count, 1)
        XCTAssertEqual(window.overlays.count, 2)
        // Evaluation across the window never throws a material error.
        for tick in stride(from: Int64(0), to: 240_000, by: 8_000) {
            XCTAssertNoThrow(try TimelineEvaluator.evaluate(window, at: try ProjectTime(ticks: tick)))
        }
    }
}
