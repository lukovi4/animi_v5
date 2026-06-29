#if DEBUG
import XCTest
import AnimiEngineCore
@testable import AnimiApp

/// Slice-005 Stage 0+1 — PARITY GUARD: the canonical video-original audio `SourceTimeMapping` (built by
/// `AppVideoOriginalAudioBridge`) must agree with the VISUAL user-video timing oracle
/// `NextVideoTimeMapping` everywhere both are defined. If these diverge, the video's original audio would
/// desync from its picture. This is the owner-required STOP guard ("STOP only if parity cannot be proven").
///
/// Contract: `SourceTimeMapping.target(sceneTime) = trimStart + rate·(sceneTicks/240000)`, with
/// `trimStart = winStart`, `rate = 1/1` ⇒ `winStart + sceneSeconds`. The visual mapping is
/// `clamp(winStart + max(0, sceneSeconds), winStart, winEnd − 1/600)`. They are identical in the interior;
/// the `winEnd − 1/600` epsilon is the resolver's read-side hold-last clamp (NOT part of the source mapping),
/// and `max(0,·)` corresponds to the evaluator never emitting negative scene-local time. The tests below
/// compare ONLY in the interior domain `[winStart, winEnd)` where the source mapping is the source of truth.
@MainActor
final class AppVideoOriginalAudioBridgeParityTests: XCTestCase {

    private func mapping(winStart: Double, winEnd: Double, volume: Float = 1, isMuted: Bool = false) throws -> SourceTimeMapping {
        let built = try AppVideoOriginalAudioBridge.build(.init(
            blockID: "block_01", sceneInstanceIDRaw: "scene-0-\(UUID().uuidString)",
            mediaReferenceRaw: "audio.videoLayer:0:block_01",
            winStart: winStart, winEnd: winEnd, volume: volume, isMuted: isMuted,
            sceneStartUs: 0, sceneDurationUs: 5_000_000,
            realAudioTrackDurationSeconds: 1000,   // large real duration so the descriptor never fails closed
            blockStartUsInScene: 0, blockEndUsInScene: 5_000_000))
        guard case let .video(binding) = built.layer.content else {
            throw XCTSkip("expected a .video layer")
        }
        return binding.sourceMapping
    }

    /// Audio source-target at a scene-local seconds instant, via the canonical mapping.
    private func audioTarget(_ m: SourceTimeMapping, sceneSeconds: Double) throws -> Double {
        // sceneSeconds → canonical scene ticks (240_000/s), then exact rational → Double for comparison.
        let ticks = Int64((sceneSeconds * Double(TickClock.ticksPerSecond)).rounded())
        let t = try m.target(for: try ScenePlaybackTime(ticks: max(0, ticks)))
        return Double(t.numerator) / Double(t.denominator)
    }

    /// The visual oracle WITHOUT the upper hold-last clamp (interior comparison domain).
    private func visualInterior(winStart: Double, sceneSeconds: Double) -> Double {
        winStart + max(0.0, sceneSeconds)
    }

    // MARK: - blockStart = 0 (frame 0 / mid)

    func test_blockStartZero_frame0_and_mid_matchVisualInterior() throws {
        let m = try mapping(winStart: 0, winEnd: 5)
        XCTAssertEqual(try audioTarget(m, sceneSeconds: 0.0), visualInterior(winStart: 0, sceneSeconds: 0.0), accuracy: 1e-9)
        XCTAssertEqual(try audioTarget(m, sceneSeconds: 1.5), visualInterior(winStart: 0, sceneSeconds: 1.5), accuracy: 1e-9)
        // Cross-check directly against the production visual mapper in its interior.
        let vis = NextVideoTimeMapping.targetVideoTime(scenePlaybackSeconds: 1.5, winStart: 0, winEnd: 5)
        XCTAssertEqual(try audioTarget(m, sceneSeconds: 1.5), vis, accuracy: 1e-9)
    }

    // MARK: - The live path feeds SCENE-LOCAL seconds (the form the resolver actually consumes)

    /// HONEST parity: the live Next resolver is fed `subplan.mediaPlaybackTime` (scene-local seconds) — the
    /// canonical evaluator has ALREADY folded any block offset / scene offset / two-clock split into that
    /// time (NextSingleSceneBridge.scenePlaybackSeconds). The audio `SourceTimeMapping` consumes the SAME
    /// scene-local time. So parity is against the seconds-form oracle (NOT a separate `blockStartFrame`
    /// argument — that argument only exists in the production frame-form mapper used for its own parity
    /// test). Authored `blockStartFrame > 0` is represented by the layer's `activeRange`, not by re-applying
    /// an offset inside the source mapping.
    func test_liveSceneLocalSeconds_matchVisualSecondsForm() throws {
        let m = try mapping(winStart: 0, winEnd: 9)
        for sceneSeconds in [0.1, 0.5, 1.0, 2.0, 4.0] {
            let vis = NextVideoTimeMapping.targetVideoTime(scenePlaybackSeconds: sceneSeconds, winStart: 0, winEnd: 9)
            XCTAssertEqual(try audioTarget(m, sceneSeconds: sceneSeconds), vis, accuracy: 1e-9, "sceneSeconds \(sceneSeconds)")
        }
    }

    /// The frame-form visual mapper with `blockStartFrame > 0` equals its OWN seconds form at
    /// `sceneSeconds = (sceneFrame − blockStartFrame)/fps`. This documents that block offset is a
    /// scene-local-TIME shift the evaluator performs upstream — the audio mapping then matches that
    /// seconds value exactly. (Pins the relationship the live path relies on; not a claim that the audio
    /// bridge itself consumes `blockStartFrame`.)
    func test_visualBlockStartFrame_isSceneLocalTimeShift_audioMatchesResultingSeconds() throws {
        let fps = 30.0, winStart = 0.0, winEnd = 9.0
        let m = try mapping(winStart: winStart, winEnd: winEnd)
        for (sceneFrame, blockStartFrame) in [(30, 30), (60, 30), (120, 30), (90, 15)] {
            let frameForm = NextVideoTimeMapping.targetVideoTime(
                sceneFrameIndex: sceneFrame, blockStartFrame: blockStartFrame, sceneFPS: fps, winStart: winStart, winEnd: winEnd)
            // The scene-local SECONDS the evaluator would hand the resolver/audio for this block frame.
            let sceneLocalSeconds = Double(sceneFrame - blockStartFrame) / fps
            XCTAssertEqual(try audioTarget(m, sceneSeconds: sceneLocalSeconds), frameForm, accuracy: 1e-9,
                "sceneFrame \(sceneFrame) blockStart \(blockStartFrame)")
        }
    }

    // MARK: - trim in/out: trimStart offset applied; trimRange = [winStart, winEnd)

    func test_trimIn_offsetApplied_matchVisual() throws {
        let m = try mapping(winStart: 2.0, winEnd: 8.0)
        // 1.0 s into the block → 2.0 + 1.0 = 3.0 (same as visual).
        let vis = NextVideoTimeMapping.targetVideoTime(scenePlaybackSeconds: 1.0, winStart: 2.0, winEnd: 8.0)
        XCTAssertEqual(try audioTarget(m, sceneSeconds: 1.0), vis, accuracy: 1e-9)
        XCTAssertEqual(try audioTarget(m, sceneSeconds: 1.0), 3.0, accuracy: 1e-9)
    }

    func test_trimRange_isHalfOpenWindow() throws {
        let m = try mapping(winStart: 2.0, winEnd: 4.0)
        XCTAssertEqual(Double(m.trimRange.start.numerator) / Double(m.trimRange.start.denominator), 2.0, accuracy: 1e-12)
        XCTAssertEqual(Double(m.trimRange.end.numerator) / Double(m.trimRange.end.denominator), 4.0, accuracy: 1e-12)
    }

    // MARK: - hold-last epsilon: the visual upper clamp is winEnd − 1/600; the audio trimRange END mirrors winEnd

    func test_holdLast_epsilon_isVisualUpperClampNotSourceMapping() throws {
        let m = try mapping(winStart: 0, winEnd: 5)
        // The audio trimRange end is winEnd exactly (the read-side clamp lives in the resolver, not the mapping).
        XCTAssertEqual(Double(m.trimRange.end.numerator) / Double(m.trimRange.end.denominator), 5.0, accuracy: 1e-12)
        // The visual oracle clamps a far frame to winEnd − epsilon; that epsilon is NOT in the source mapping.
        let visFar = NextVideoTimeMapping.targetVideoTime(scenePlaybackSeconds: 100_000, winStart: 0, winEnd: 5)
        XCTAssertEqual(visFar, 5.0 - NextVideoTimeMapping.epsilon, accuracy: 1e-12)
        XCTAssertEqual(NextVideoTimeMapping.epsilon, 1.0 / 600.0, accuracy: 0)
    }

    // MARK: - Broad interior sweep across windows + scene seconds

    func test_paritySweep_interior_matchesVisualEverywhere() throws {
        let windows: [(Double, Double)] = [(0, 5), (0.5, 9), (2, 4), (1.0, 6.0)]
        for (ws, we) in windows {
            let m = try mapping(winStart: ws, winEnd: we)
            // Sample scene seconds strictly inside [0, we-ws) so we stay in the interior (below the clamp).
            let span = we - ws
            for k in stride(from: 0.0, to: span, by: max(0.05, span / 20.0)) {
                let vis = NextVideoTimeMapping.targetVideoTime(scenePlaybackSeconds: k, winStart: ws, winEnd: we)
                XCTAssertEqual(try audioTarget(m, sceneSeconds: k), vis, accuracy: 1e-9, "win[\(ws),\(we)] k=\(k)")
            }
        }
    }

    // MARK: - volume / mute carried onto the clip (not the mapping)

    func test_volumeAndMute_carriedOntoClip() throws {
        let built = try AppVideoOriginalAudioBridge.build(.init(
            blockID: "b", sceneInstanceIDRaw: "scene-0-x", mediaReferenceRaw: "audio.videoLayer:0:b",
            winStart: 0, winEnd: 5, volume: 0.5, isMuted: true,
            sceneStartUs: 0, sceneDurationUs: 5_000_000,
            realAudioTrackDurationSeconds: 1000,
            blockStartUsInScene: 0, blockEndUsInScene: 5_000_000))
        XCTAssertTrue(built.clip.isMuted)
        XCTAssertEqual(built.clip.gain.raw, 500_000, "volume 0.5 → gain 500000")
        XCTAssertEqual(built.clip.playbackPolicy, .once)
        XCTAssertEqual(built.track.role, .videoLayer)
        guard case .videoLayerMedia = built.source.asset else { return XCTFail("source must be .videoLayerMedia") }
        XCTAssertNotNil(built.clip.videoLayer, "video clip carries a SceneLayerReference")
    }

    // MARK: - Non-zero block interval (#3 / P1): FAIL-CLOSED — not supported this stage

    /// A non-scene-filling block (blockStart > 0 OR blockEnd != sceneDuration) is FAIL-CLOSED: the canonical
    /// evaluator's scene-local clock would compute `sourceStart = winStart + offset` (wrong), so the bridge
    /// throws typed `mediaUnsupported` rather than emit a mis-timed segment. Authored partial block timing is
    /// a documented remaining follow-up.
    func test_nonZeroBlockStart_failsClosed() throws {
        XCTAssertThrowsError(try AppVideoOriginalAudioBridge.build(.init(
            blockID: "b", sceneInstanceIDRaw: "scene-1-x", mediaReferenceRaw: "audio.videoLayer:1:b",
            winStart: 0, winEnd: 3, volume: 1, isMuted: false,
            sceneStartUs: 2_000_000, sceneDurationUs: 5_000_000,
            blockStartUsInScene: 1_000_000, blockEndUsInScene: 4_000_000))) { error in
            guard case .mediaUnsupported? = error as? AppRealtimeAudioIntegrationError else {
                return XCTFail("expected mediaUnsupported, got \(error)")
            }
        }
    }

    func test_partialBlockEnd_failsClosed() throws {
        // blockStart = 0 but blockEnd != sceneDuration (block ends before the scene) → fail-closed.
        XCTAssertThrowsError(try AppVideoOriginalAudioBridge.build(.init(
            blockID: "b", sceneInstanceIDRaw: "scene-0-x", mediaReferenceRaw: "audio.videoLayer:0:b",
            winStart: 0, winEnd: 3, volume: 1, isMuted: false,
            sceneStartUs: 0, sceneDurationUs: 5_000_000,
            blockStartUsInScene: 0, blockEndUsInScene: 4_000_000)))
    }

    // MARK: - Scene-filling positive: destination/activeRange valid (block == whole scene)

    func test_sceneFilling_destinationAndActiveRange_spanWholeScene() throws {
        // Scene at project 2s, duration 5s; block fills it → destination [2s, 7s), activeRange [0, 5s).
        let built = try AppVideoOriginalAudioBridge.build(.init(
            blockID: "b", sceneInstanceIDRaw: "scene-1-x", mediaReferenceRaw: "audio.videoLayer:1:b",
            winStart: 0, winEnd: 5, volume: 1, isMuted: false,
            sceneStartUs: 2_000_000, sceneDurationUs: 5_000_000,
            realAudioTrackDurationSeconds: 1000,
            blockStartUsInScene: 0, blockEndUsInScene: 5_000_000))
        XCTAssertEqual(built.clip.destination.start.ticks, 480_000, "dest start = scene start (2s)")
        XCTAssertEqual(built.clip.destination.end.ticks, 1_680_000, "dest end = scene end (7s)")
        XCTAssertEqual(built.layer.activeRange.start.ticks, 0, "activeRange starts at scene tick 0")
        XCTAssertEqual(built.layer.activeRange.end.ticks, 1_200_000, "activeRange spans the scene (5s)")
    }

    // MARK: - Source descriptor duration (Stage-9.2): REAL probed audio-track duration, NOT winEnd

    /// Stage-9.2: the descriptor's `sourceDuration` is the REAL probed audio-track duration, not the `winEnd`
    /// lower bound. Here the real track is 8.5 s while winEnd is 8 s → sourceDuration must be 8.5, not 8.
    func test_S92_sourceDescriptorDuration_isRealProbedDuration_notWinEnd() throws {
        let built = try AppVideoOriginalAudioBridge.build(.init(
            blockID: "b", sceneInstanceIDRaw: "scene-0-x", mediaReferenceRaw: "audio.videoLayer:0:b",
            winStart: 2, winEnd: 8, volume: 1, isMuted: false,
            sceneStartUs: 0, sceneDurationUs: 9_000_000,
            realAudioTrackDurationSeconds: 8.5,
            blockStartUsInScene: 0, blockEndUsInScene: 9_000_000))
        let d = Double(built.descriptor.sourceDuration.numerator) / Double(built.descriptor.sourceDuration.denominator)
        XCTAssertEqual(d, 8.5, accuracy: 1e-9, "sourceDuration = REAL probed track duration (8.5 s), not winEnd (8 s)")
        XCTAssertNotEqual(d, 8.0, accuracy: 1e-9, "must NOT be the winEnd lower bound")
    }

    /// Stage-9.2: when the real track is SHORTER than winEnd (the S9.2 device case — a stretched scene maps
    /// past the real audio), the descriptor uses the real (shorter) duration so segment.sourceEnd ≤ real
    /// track and the renderer's Stage-8.1 clamp can bound the decode. Here winEnd=12 but real track=11.9.
    func test_S92_realTrackShorterThanWinEnd_descriptorUsesRealDuration() throws {
        let built = try AppVideoOriginalAudioBridge.build(.init(
            blockID: "b", sceneInstanceIDRaw: "scene-0-x", mediaReferenceRaw: "audio.videoLayer:0:b",
            winStart: 0, winEnd: 12, volume: 1, isMuted: false,
            sceneStartUs: 0, sceneDurationUs: 12_000_000,
            realAudioTrackDurationSeconds: 11.9,
            blockStartUsInScene: 0, blockEndUsInScene: 12_000_000))
        let d = Double(built.descriptor.sourceDuration.numerator) / Double(built.descriptor.sourceDuration.denominator)
        XCTAssertEqual(d, 11.9, accuracy: 1e-9, "real track (11.9 s) shorter than winEnd (12 s) → descriptor 11.9")
        XCTAssertLessThan(d, 12.0, "sourceDuration must be the real (shorter) track, not winEnd")
    }

    /// Stage-9.2: a missing probed duration FAILS CLOSED (typed) — never silently falls back to winEnd.
    func test_S92_missingRealDuration_failsClosed() {
        XCTAssertThrowsError(try AppVideoOriginalAudioBridge.build(.init(
            blockID: "b", sceneInstanceIDRaw: "scene-0-x", mediaReferenceRaw: "audio.videoLayer:0:b",
            winStart: 0, winEnd: 5, volume: 1, isMuted: false,
            sceneStartUs: 0, sceneDurationUs: 5_000_000,
            realAudioTrackDurationSeconds: nil,
            blockStartUsInScene: 0, blockEndUsInScene: 5_000_000))) { error in
            guard case .audioAssetUnresolvable? = error as? AppRealtimeAudioIntegrationError else {
                return XCTFail("missing real duration must fail closed (audioAssetUnresolvable), got \(error)")
            }
        }
    }

    /// Stage-9.2: an invalid (≤ 0 / non-finite) probed duration FAILS CLOSED.
    func test_S92_invalidRealDuration_failsClosed() {
        for bad in [0.0, -1.0, Double.nan, Double.infinity] {
            XCTAssertThrowsError(try AppVideoOriginalAudioBridge.build(.init(
                blockID: "b", sceneInstanceIDRaw: "scene-0-x", mediaReferenceRaw: "audio.videoLayer:0:b",
                winStart: 0, winEnd: 5, volume: 1, isMuted: false,
                sceneStartUs: 0, sceneDurationUs: 5_000_000,
                realAudioTrackDurationSeconds: bad,
                blockStartUsInScene: 0, blockEndUsInScene: 5_000_000)), "duration \(bad) must fail closed")
        }
    }

    // MARK: - Stage-7 S6: destination.start must equal the media-active domain.start (no floor(Σµs) drift)

    /// Reproduces the confirmed S6 device blocker (`s6-boundary-probe.log:252`): a preceding scene duration of
    /// `8766667 µs` is NOT tick-aligned. `8766667·6/25 = 2104000.08` → `floor=2104000`, `ceil=2104001`.
    /// The media-active domain.start for scene-1 is `Σ ceilTicks(preceding) = 2104001`. The OLD path computed
    /// destination.start = `floorTicks(Σ µs) = 2104000` — 1 tick BELOW domain.start → `incomingAudioBeforeBoundary`.
    /// The NEW tick path (caller passes the cumulative-ceil scene start ticks) makes destination.start ==
    /// domain.start, so validation passes. Integer tick math only.
    func test_S6_destinationStart_equalsDomainStart_forNonTickAlignedPrecedingScene() throws {
        // Domain basis: scene-0 span = ceilTicks(8766667), scene-1 start = that sum.
        let scene0SpanTicks = Slice005TickProjection.ceilTicks(8_766_667)!
        let scene1DomainStart = scene0SpanTicks                         // Σ ceilTicks(preceding) for index 1
        let scene1Span = Slice005TickProjection.ceilTicks(5_000_000)!   // scene-1 duration 5s (tick-aligned)
        let scene1DomainEnd = scene1DomainStart + scene1Span

        // Confirm the arithmetic the probe captured.
        XCTAssertEqual(Slice005TickProjection.floorTicks(8_766_667), 2_104_000, "old floor(Σµs) basis")
        XCTAssertEqual(scene0SpanTicks, 2_104_001, "ceil basis (domain) is 1 tick higher")
        XCTAssertEqual(scene1DomainStart, 2_104_001)

        // NEW tick path: caller supplies the cumulative-ceil scene start/end ticks.
        let built = try AppVideoOriginalAudioBridge.build(.init(
            blockID: "block_01", sceneInstanceIDRaw: "scene-1-y", mediaReferenceRaw: "audio.videoLayer:1:block_01",
            winStart: 0, winEnd: 5, volume: 1, isMuted: false,
            sceneStartUs: 8_766_667, sceneDurationUs: 5_000_000,
            sceneStartTicks: scene1DomainStart, sceneEndTicks: scene1DomainEnd,
            realAudioTrackDurationSeconds: 1000,
            blockStartUsInScene: 0, blockEndUsInScene: 5_000_000))

        XCTAssertEqual(built.clip.destination.start.ticks, scene1DomainStart,
                       "S6 fix: destination.start == domain.start (2104001), not floor(Σµs) 2104000")
        XCTAssertEqual(built.clip.destination.end.ticks, scene1DomainEnd,
                       "destination.end == domain.end for the scene-filling span")
        // Prove the OLD path WOULD have failed: floor(Σµs) start is strictly below domain.start.
        XCTAssertLessThan(Slice005TickProjection.floorTicks(8_766_667)!, scene1DomainStart,
                          "old floor(Σµs) destination.start was 1 tick below domain.start → incomingAudioBeforeBoundary")
    }

    /// A tick-aligned preceding scene (5_000_000 µs) has floor == ceil, so the OLD path already validated;
    /// the NEW path must agree (no regression for the previously-passing case).
    func test_S6_tickAlignedPrecedingScene_unchanged() throws {
        let scene0SpanTicks = Slice005TickProjection.ceilTicks(5_000_000)!
        XCTAssertEqual(Slice005TickProjection.floorTicks(5_000_000), scene0SpanTicks, "tick-aligned: floor == ceil")
        let built = try AppVideoOriginalAudioBridge.build(.init(
            blockID: "block_01", sceneInstanceIDRaw: "scene-1-z", mediaReferenceRaw: "audio.videoLayer:1:block_01",
            winStart: 0, winEnd: 5, volume: 1, isMuted: false,
            sceneStartUs: 5_000_000, sceneDurationUs: 5_000_000,
            sceneStartTicks: scene0SpanTicks, sceneEndTicks: scene0SpanTicks + Slice005TickProjection.ceilTicks(5_000_000)!,
            realAudioTrackDurationSeconds: 1000,
            blockStartUsInScene: 0, blockEndUsInScene: 5_000_000))
        XCTAssertEqual(built.clip.destination.start.ticks, 1_200_000, "5s start, tick-aligned")
        XCTAssertEqual(built.clip.destination.end.ticks, 2_400_000, "10s end")
    }
}
#endif
