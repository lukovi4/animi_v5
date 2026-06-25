import XCTest
@testable import AnimiEngineCore

/// Slice-003 Stage D — complete-frame worksets + single-time/single-epoch publication (ADR-005 §5/§6,
/// ADR-006 §6).
///
/// Proves: a multi-layer workset publishes one synchronized frame or nothing; required inputs are
/// derived from the FramePlan (not invented); a transition workset stays one exact target time; a
/// mixed-time or mixed-epoch composition is rejected (never a per-layer lastGood substitution).
final class WorksetMixedTimeTests: XCTestCase {

    // MARK: - required inputs are derived from the FramePlan

    func testRequiredInputsDerivedFromSingleScenePlan() throws {
        let f = try Fixture.sixVideoLayers(time: 240_000)
        // Exactly the six layers the plan carries, all scene-layer video inputs — nothing invented.
        XCTAssertEqual(f.rendered.workset.requiredInputs.count, 6)
        for input in f.rendered.workset.requiredInputs {
            guard case let .sceneLayer(_, _, kind) = input else { return XCTFail("expected scene layer") }
            XCTAssertEqual(kind, .video)
        }
    }

    func testRequiredInputsIncludeOverlays() throws {
        let f = try Fixture.singleVideo(time: 240_000, overlayCount: 2)
        let overlays = f.rendered.workset.requiredInputs.filter { if case .overlay = $0 { return true }; return false }
        XCTAssertEqual(overlays.count, 2)
    }

    // MARK: - six-layer workset publishes one synchronized frame OR nothing

    func testSixLayerWorksetPublishesOneSynchronizedFrame() throws {
        let f = try Fixture.sixVideoLayers(time: 240_000)
        guard case .publish = PublicationGate.evaluate(candidate: f.rendered, against: f.snapshot) else {
            return XCTFail("a fully resolved six-layer workset must publish one frame")
        }
    }

    func testSixLayerWorksetWithOneLayerUnresolvedPublishesNothing() throws {
        // Resolve only five of six layers → missing dependency → nothing published (no partial frame).
        let f = try Fixture.sixVideoLayers(time: 240_000, resolveLayers: 5)
        XCTAssertEqual(PublicationGate.evaluate(candidate: f.rendered, against: f.snapshot),
                       .keepPrevious(reason: .missingDependency))
    }

    // MARK: - mixed-epoch dependency rejected (no per-layer lastGood from a previous epoch)

    func testMixedEpochDependencyRejected() throws {
        // Five of six layers resolved under the candidate epoch; ONE resolved under a previous epoch —
        // exactly the per-layer-lastGood pattern ADR-005 §6 forbids.
        let f = try Fixture.sixVideoLayers(time: 240_000, oneLayerFromEpoch: PlaybackEpoch(raw: 0))
        XCTAssertEqual(PublicationGate.evaluate(candidate: f.rendered, against: f.snapshot),
                       .keepPrevious(reason: .incompleteComposition))
    }

    // MARK: - mixed-time dependency rejected (workset internal time disagreement)

    func testMixedTimeWorksetRejected() throws {
        // identity.time disagrees with plan.projectTime → the workset is internally mixed-time.
        let f = try Fixture.singleVideo(time: 240_000, identityTimeOverride: 480_000)
        XCTAssertFalse(f.rendered.workset.isInternallyConsistent)
        XCTAssertEqual(PublicationGate.evaluate(candidate: f.rendered, against: f.snapshot),
                       .keepPrevious(reason: .incompleteComposition))
    }

    // MARK: - transition workset stays one exact target time

    func testTransitionWorksetIsOneExactTargetTime() throws {
        let f = try Fixture.transition(time: 240_000)
        // The transition body has outgoing + incoming subplans, but the workset is one project time.
        XCTAssertEqual(f.rendered.workset.projectTime, try Fixture.t(240_000))
        XCTAssertTrue(f.rendered.workset.isInternallyConsistent)
        // Required inputs span both subplans, all at the single target time; resolved fully ⇒ publish.
        XCTAssertGreaterThanOrEqual(f.rendered.workset.requiredInputs.count, 2)
        guard case .publish = PublicationGate.evaluate(candidate: f.rendered, against: f.snapshot) else {
            return XCTFail("a fully resolved transition workset must publish one frame")
        }
    }

    func testTransitionWorksetRequiresBothSubplanInputs() throws {
        // Drop the incoming subplan's input receipts → incomplete → nothing published.
        let f = try Fixture.transition(time: 240_000, resolveIncoming: false)
        XCTAssertEqual(PublicationGate.evaluate(candidate: f.rendered, against: f.snapshot),
                       .keepPrevious(reason: .missingDependency))
    }
}

// MARK: - Shared fixtures (used by PublicationGateTests + WorksetMixedTimeTests)

enum Fixture {

    struct Bundle {
        let rendered: RenderAttempt
        let snapshot: SchedulerSnapshot
        let revision: ProjectRevision
        let epoch: PlaybackEpoch
        let frameRequest: FrameRequestID
    }

    static func t(_ ticks: Int64) throws -> ProjectTime { try ProjectTime(ticks: ticks) }
    static func range(_ s: Int64, _ e: Int64) throws -> ProjectTimeRange {
        try ProjectTimeRange(start: try t(s), end: try t(e))
    }

    // MARK: building blocks

    private static func output() throws -> OutputContext {
        OutputContext(canvas: try CanvasSize(width: 1080, height: 1920), frameRate: .fps30)
    }

    private static func placement() throws -> Placement {
        try Placement(
            frame: try FixedRect(
                x: CanvasScalar(rawValue: 0), y: CanvasScalar(rawValue: 0),
                width: CanvasScalar(rawValue: 1080), height: CanvasScalar(rawValue: 1920)
            ),
            scale: .one, rotation: .zero
        )
    }

    private static func videoLayer(_ index: Int) throws -> ActiveLayer {
        let request = SourceRequest(
            media: try MediaReference("media-\(index)"),
            target: try RationalSourceTime(numerator: 0, denominator: 1),
            selection: .presentationIntervalContainsTarget
        )
        return ActiveLayer(
            layerID: try LayerID("L\(index)"), zIndex: index, stableOrdinal: index, localCompositionOrder: index,
            placement: try placement(), mediaPlacement: .identity(fitMode: .cover),
            content: .video(request), animationReference: nil, animationRequest: nil
        )
    }

    private static func subplan(sceneID: String, role: SceneRole, layerCount: Int) throws -> SceneSubplan {
        SceneSubplan(
            sceneID: try SceneInstanceID(sceneID), role: role,
            visualPlaybackTime: .zero, mediaPlaybackTime: .zero, transitionRelativeTime: nil,
            layers: try (0..<layerCount).map { try videoLayer($0) }
        )
    }

    private static func overlay(_ index: Int) throws -> ActiveOverlay {
        ActiveOverlay(
            overlayID: try OverlayID("O\(index)"), zIndex: index, stableOrdinal: index, compositionOrder: index,
            placement: try placement(), content: .sticker(try ImageReference("img-\(index)")),
            animationReference: nil, animationRequest: nil, playbackTime: try OverlayPlaybackTime(ticks: 0)
        )
    }

    // MARK: bundle assembly

    /// Assemble a bundle from a finished plan: derive the workset, render a token, resolve receipts.
    private static func assemble(
        plan: FramePlan,
        revision: ProjectRevision = ProjectRevision(raw: 1),
        epoch: PlaybackEpoch = PlaybackEpoch(raw: 5),
        frameRequest: FrameRequestID = FrameRequestID(raw: 1),
        identityTimeOverride: Int64? = nil,
        resolveCount: Int? = nil,
        resolveIncoming: Bool = true,
        oneLayerFromEpoch: PlaybackEpoch? = nil,
        postRenderRevalidated: Bool = true,
        publishedQualityOverride: String? = nil
    ) throws -> Bundle {
        let quality = try QualityProfileID("high")
        let publishedQuality = try publishedQualityOverride.map { try QualityProfileID($0) } ?? quality
        let identityTime = try identityTimeOverride.map { try t($0) } ?? plan.projectTime
        let identity = RequestIdentity(
            revision: revision, epoch: epoch, frameRequest: frameRequest, time: identityTime, quality: quality
        )
        let workset = FrameWorkset(identity: identity, plan: plan)

        // Resolve receipts from the workset's derived required inputs.
        var required = workset.requiredInputs
        if !resolveIncoming {
            // Keep only the first subplan's inputs (outgoing) by dropping inputs of the incoming scene.
            if case let .transition(transition) = plan.body {
                let incomingScene = transition.incoming.sceneID
                required = required.filter {
                    if case let .sceneLayer(scene, _, _) = $0 { return scene != incomingScene }
                    return true
                }
            }
        }
        if let resolveCount { required = Array(required.prefix(resolveCount)) }

        var receipts = required.map { ResolvedInputReceipt(input: $0, producedUnderEpoch: epoch) }
        if let stale = oneLayerFromEpoch, !receipts.isEmpty {
            receipts[0] = ResolvedInputReceipt(input: receipts[0].input, producedUnderEpoch: stale)
        }

        let published = PublishedFrame(
            revision: revision, epoch: epoch, frameRequest: frameRequest, time: plan.projectTime,
            quality: publishedQuality, composition: try ComposedFrameHandle("composed-\(plan.projectTime.ticks)")
        )
        let rendered = RenderAttempt(
            workset: workset, published: published, resolvedInputs: receipts,
            postRenderRevalidated: postRenderRevalidated
        )
        let snapshot = SchedulerSnapshot(
            revision: revision, epoch: epoch, coverage: try range(0, 600_000),
            currentTarget: CurrentTarget(time: plan.projectTime, frameRequest: frameRequest),
            lastPublished: nil
        )
        return Bundle(rendered: rendered, snapshot: snapshot, revision: revision, epoch: epoch, frameRequest: frameRequest)
    }

    // MARK: public scenarios

    static func singleVideo(
        time: Int64, overlayCount: Int = 0, resolveAllInputs: Bool = true,
        identityTimeOverride: Int64? = nil, postRenderRevalidated: Bool = true,
        publishedQualityOverride: String? = nil
    ) throws -> Bundle {
        let plan = FramePlan(
            output: try output(), projectTime: try t(time),
            body: .single(try subplan(sceneID: "S0", role: .sole, layerCount: 1)),
            overlays: try (0..<overlayCount).map { try overlay($0) }
        )
        return try assemble(
            plan: plan, identityTimeOverride: identityTimeOverride,
            resolveCount: resolveAllInputs ? nil : 0, postRenderRevalidated: postRenderRevalidated,
            publishedQualityOverride: publishedQualityOverride
        )
    }

    static func sixVideoLayers(
        time: Int64, resolveLayers: Int? = nil, oneLayerFromEpoch: PlaybackEpoch? = nil
    ) throws -> Bundle {
        let plan = FramePlan(
            output: try output(), projectTime: try t(time),
            body: .single(try subplan(sceneID: "S0", role: .sole, layerCount: 6)),
            overlays: []
        )
        return try assemble(plan: plan, resolveCount: resolveLayers, oneLayerFromEpoch: oneLayerFromEpoch)
    }

    static func transition(time: Int64, resolveIncoming: Bool = true) throws -> Bundle {
        let transition = TransitionPlan(
            effectID: try TransitionEffectID("fade"),
            parameters: .empty, easing: try EasingReference("linear"),
            progressNumerator: 1, progressDenominator: 2,
            outgoing: try subplan(sceneID: "S0", role: .outgoing, layerCount: 1),
            incoming: try subplan(sceneID: "S1", role: .incoming, layerCount: 1)
        )
        let plan = FramePlan(
            output: try output(), projectTime: try t(time), body: .transition(transition), overlays: []
        )
        return try assemble(plan: plan, resolveIncoming: resolveIncoming)
    }
}

// MARK: - SchedulerSnapshot fluent mutators (test-only)

extension SchedulerSnapshot {
    func with(revision: ProjectRevision) -> SchedulerSnapshot {
        SchedulerSnapshot(revision: revision, epoch: epoch, coverage: coverage, currentTarget: currentTarget, lastPublished: lastPublished)
    }
    func with(epoch: PlaybackEpoch) -> SchedulerSnapshot {
        SchedulerSnapshot(revision: revision, epoch: epoch, coverage: coverage, currentTarget: currentTarget, lastPublished: lastPublished)
    }
    func with(coverage: ProjectTimeRange) -> SchedulerSnapshot {
        SchedulerSnapshot(revision: revision, epoch: epoch, coverage: coverage, currentTarget: currentTarget, lastPublished: lastPublished)
    }
    func with(currentTarget: CurrentTarget) -> SchedulerSnapshot {
        SchedulerSnapshot(revision: revision, epoch: epoch, coverage: coverage, currentTarget: currentTarget, lastPublished: lastPublished)
    }
    func with(lastPublished: PublishedIdentitySummary?) -> SchedulerSnapshot {
        SchedulerSnapshot(revision: revision, epoch: epoch, coverage: coverage, currentTarget: currentTarget, lastPublished: lastPublished)
    }
}

// MARK: - Fake render source (test-only)

extension Fixture {
    struct FakeRenderSource: RenderResultSource {
        let result: PublishedFrame
        func render(_ workset: FrameWorkset) throws -> PublishedFrame { result }
    }
}
