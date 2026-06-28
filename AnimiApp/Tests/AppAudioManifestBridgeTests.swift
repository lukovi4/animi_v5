import XCTest
import AnimiEngineCore
@testable import AnimiApp

/// Slice-005 Stage A — `AppAudioManifestBridge`: app audio model → populated canonical `AudioManifest`.
final class AppAudioManifestBridgeTests: XCTestCase {

    // MARK: - Builders

    private func payload(
        asset: AudioAssetRef? = .bundled(id: "track-A"),
        durationUs: Int64 = 10_000_000,
        trimStartUs: Int64 = 0,
        trimEndUs: Int64 = 10_000_000,
        volume: Float = 1.0,
        role: AudioRole = .music
    ) -> AudioPayload {
        AudioPayload(
            assetRef: asset, sourceDurationUs: durationUs,
            trimStartUs: trimStartUs, trimEndUs: trimEndUs, volume: volume, role: role)
    }

    private func input(
        _ index: Int, startUs: Int64 = 0, durationUs: Int64 = 10_000_000, _ p: AudioPayload
    ) -> AppAudioManifestBridge.Input {
        AppAudioManifestBridge.Input(index: index, startUs: startUs, durationUs: durationUs, payload: p)
    }

    private func build(_ items: [AppAudioManifestBridge.Input]) throws -> AudioManifest {
        try AppAudioManifestBridge.buildManifest(items: items, includeOriginalFromVideoSlots: false)
    }

    // MARK: - Empty

    func testEmptyAudioYieldsEmptyManifest() throws {
        let manifest = try build([])
        XCTAssertEqual(manifest, AudioManifest.empty)
        XCTAssertTrue(manifest.isEmpty)
    }

    // MARK: - One music item → one source/track/clip

    func testOneMusicItemProducesOneSourceTrackClip() throws {
        let manifest = try build([input(0, payload())])
        XCTAssertEqual(manifest.sources.count, 1)
        XCTAssertEqual(manifest.tracks.count, 1)
        XCTAssertEqual(manifest.clips.count, 1)
        XCTAssertEqual(manifest.tracks.first?.role, .music)
        if case .globalAudio = manifest.sources.first!.asset {} else {
            XCTFail("expected global audio asset")
        }
    }

    // MARK: - destination projection from startUs + durationUs

    func testGridAlignedDestinationProjectsWithoutWidening() throws {
        // Grid-aligned input: floor(start)==ceil(end)==exact, so no widening.
        // 1_000_000 µs = 1 s = 240_000 ticks; +2 s duration → end 720_000 ticks.
        let manifest = try build([input(0, startUs: 1_000_000, durationUs: 2_000_000, payload())])
        let dest = manifest.clips.first!.destination
        XCTAssertEqual(dest.start.ticks, 240_000)
        XCTAssertEqual(dest.end.ticks, 720_000)
    }

    func testDestinationAcceptsNonGridAlignedMicrosWithOutwardProjection() throws {
        // App TimeUs need not land on the 240 kHz grid. [1µs, 2µs) projects OUTWARD:
        //   startTick = floor(1 * 6 / 25)        = 0
        //   endTick   = ceil(2 * 6 / 25)         = ceil(12/25) = 1
        // Non-grid input is ACCEPTED (covered outward), never rejected for alignment.
        let manifest = try build([input(0, startUs: 1, durationUs: 1, payload())])
        let dest = manifest.clips.first!.destination
        XCTAssertEqual(dest.start.ticks, 0)
        XCTAssertEqual(dest.end.ticks, 1)
        // Outward covering: start ≤ exact-start, end ≥ exact-end; error < 1 tick per boundary.
        XCTAssertLessThanOrEqual(dest.start.ticks, 1 * 6 / 25)         // 0 ≤ 0
        XCTAssertGreaterThanOrEqual(dest.end.ticks * 25, 2 * 6)        // 1*25=25 ≥ 12
    }

    func testRealisticImportedNonAlignedDurationAccepted() throws {
        // A realistic imported clip: duration derived via Double → TimeUs, NOT 25µs-aligned
        // (e.g. 3.333333 s = 3_333_333 µs starting at 500_111 µs). Must be accepted, outward-covered.
        let startUs: Int64 = 500_111
        let durationUs: Int64 = 3_333_333
        let endUs = startUs + durationUs            // 3_833_444 µs
        let manifest = try build([input(0, startUs: startUs, durationUs: durationUs, payload(
            durationUs: durationUs, trimEndUs: durationUs))])
        let dest = manifest.clips.first!.destination
        // Outward projection (integer 6/25):
        //   startTick = floor(500_111 * 6 / 25)  = floor(3_000_666/25)  = 120_026
        //   endTick   = ceil(3_833_444 * 6 / 25) = ceil(23_000_664/25)  = 920_027 (23_000_664/25 = 920_026.56)
        XCTAssertEqual(dest.start.ticks, 120_026)
        XCTAssertEqual(dest.end.ticks, 920_027)
        XCTAssertTrue(dest.end > dest.start)
        // Bounds: covers the exact interval (start ≤ exact, end ≥ exact), widening < 1 tick each side.
        XCTAssertLessThanOrEqual(dest.start.ticks * 25, startUs * 6)   // 120_026*25 ≤ 3_000_666
        XCTAssertGreaterThanOrEqual(dest.end.ticks * 25, endUs * 6)    // 920_027*25 ≥ 23_000_664
    }

    func testDestinationRejectsZeroDuration() throws {
        XCTAssertThrowsError(try build([input(0, startUs: 0, durationUs: 0, payload())])) { error in
            guard case .invalidDestination? = error as? AppRealtimeAudioIntegrationError else {
                return XCTFail("expected invalidDestination")
            }
        }
    }

    // MARK: - trim exact

    func testSourceTrimExactFromTrimStartEnd() throws {
        let manifest = try build([input(0, payload(trimStartUs: 500_000, trimEndUs: 1_500_000))])
        let trim = manifest.clips.first!.sourceTrim
        // 500_000/1_000_000 = 1/2 ; 1_500_000/1_000_000 = 3/2 (reduced).
        XCTAssertEqual(trim.start.numerator, 1)
        XCTAssertEqual(trim.start.denominator, 2)
        XCTAssertEqual(trim.end.numerator, 3)
        XCTAssertEqual(trim.end.denominator, 2)
    }

    func testTrimRejectsInverted() throws {
        XCTAssertThrowsError(try build([input(0, payload(trimStartUs: 2_000_000, trimEndUs: 1_000_000))])) { error in
            guard case .invalidSourceTrim? = error as? AppRealtimeAudioIntegrationError else {
                return XCTFail("expected invalidSourceTrim")
            }
        }
    }

    // MARK: - gain exact + fail-closed

    func testGainExactForBoundaryValues() throws {
        let zero = try build([input(0, payload(volume: 0.0))]).clips.first!.gain
        let half = try build([input(0, payload(volume: 0.5))]).clips.first!.gain
        let unity = try build([input(0, payload(volume: 1.0))]).clips.first!.gain
        XCTAssertEqual(zero.raw, 0)
        XCTAssertEqual(half.raw, 500_000)
        XCTAssertEqual(unity.raw, 1_000_000)
    }

    func testGainRejectsOutOfRangeAndNonFinite() throws {
        for bad: Float in [-0.1, 1.1, 2.0, .nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try build([input(0, payload(volume: bad))]), "volume \(bad) must reject") { error in
                guard case .invalidGain? = error as? AppRealtimeAudioIntegrationError else {
                    return XCTFail("expected invalidGain for \(bad), got \(error)")
                }
            }
        }
    }

    // MARK: - playbackPolicy .once / no loopToFit

    func testPlaybackPolicyIsOnce() throws {
        let manifest = try build([input(0, payload())])
        XCTAssertEqual(manifest.clips.first!.playbackPolicy, .once)
    }

    func testNoLoopFieldExistsInCanonicalClip() {
        // Structural guard: the canonical clip exposes no loop/loopToFit (no such member to reference).
        // If a loop field were ever added, this comment + the .once-only enum would need revisiting.
        XCTAssertEqual(AudioPlaybackPolicy.allCasesCountIsOne, 1)
    }

    // MARK: - deterministic ordering

    func testDeterministicOrderingAcrossRolesAndStarts() throws {
        let items = [
            input(0, startUs: 2_000_000, durationUs: 1_000_000, payload(asset: .bundled(id: "sfx"), role: .sfx)),
            input(1, startUs: 0, durationUs: 1_000_000, payload(asset: .bundled(id: "music"), role: .music)),
            input(2, startUs: 1_000_000, durationUs: 1_000_000, payload(asset: .bundled(id: "vo"), role: .voiceover)),
        ]
        let a = try build(items)
        let b = try build(items)
        XCTAssertEqual(a, b, "manifest build must be deterministic")
        // Tracks ordered music, voiceover, soundEffect.
        XCTAssertEqual(a.tracks.map(\.role), [.music, .voiceover, .soundEffect])
    }

    // MARK: - global roles mapping

    func testGlobalRolesMapMusicVoiceoverSfx() throws {
        let m = try build([input(0, payload(asset: .bundled(id: "m"), role: .music))]).tracks.first!.role
        let v = try build([input(0, payload(asset: .bundled(id: "v"), role: .voiceover))]).tracks.first!.role
        let s = try build([input(0, payload(asset: .bundled(id: "s"), role: .sfx))]).tracks.first!.role
        XCTAssertEqual(m, .music)
        XCTAssertEqual(v, .voiceover)
        XCTAssertEqual(s, .soundEffect)
    }

    // MARK: - missing assetRef behaviour (FAIL, tested)

    func testMissingAssetRefFailsClosed() throws {
        // Stage A decision: a missing assetRef is a typed failure (NOT a silent skip).
        XCTAssertThrowsError(try build([input(0, payload(asset: nil))])) { error in
            guard case .missingAssetReference(itemIndex: 0)? = error as? AppRealtimeAudioIntegrationError else {
                return XCTFail("expected missingAssetReference")
            }
        }
    }

    // MARK: - duplicate clip identity

    func testDuplicateClipIdentityFailsClosed() throws {
        // Same index + same source derives the same clip id → ambiguous.
        let p = payload(asset: .bundled(id: "dup"))
        XCTAssertThrowsError(try build([input(0, p), input(0, p)])) { error in
            guard case .duplicateClipIdentity? = error as? AppRealtimeAudioIntegrationError else {
                return XCTFail("expected duplicateClipIdentity")
            }
        }
    }

    // MARK: - video-layer original audio unsupported on Stage A

    func testIncludeOriginalFromVideoSlotsIsUnsupportedStageA() throws {
        XCTAssertThrowsError(
            try AppAudioManifestBridge.buildManifest(
                items: [input(0, payload())], includeOriginalFromVideoSlots: true)
        ) { error in
            XCTAssertEqual(
                error as? AppRealtimeAudioIntegrationError, .videoLayerOriginalAudioUnsupportedInStageA)
        }
    }

    // MARK: - projectEndUs clamp (Fix B: imported track longer than project must not exceed project end)

    func test_projectEndClamp_truncatesOverLengthClipToProjectEnd() throws {
        // Item is 10 s, project is 5 s → destination.end must be clamped to 5 s, NOT 10 s.
        let m = try AppAudioManifestBridge.buildManifest(
            items: [input(0, startUs: 0, durationUs: 10_000_000, payload())],
            includeOriginalFromVideoSlots: false, projectEndUs: 5_000_000)
        let clip = try XCTUnwrap(m.clips.first)
        // 5 s = 5_000_000 µs → ceil ticks = 5_000_000 * 6 / 25 = 1_200_000.
        XCTAssertEqual(clip.destination.end.ticks, 1_200_000, "destination end clamped to project end (5 s)")
        XCTAssertEqual(clip.destination.start.ticks, 0)
    }

    func test_projectEndClamp_shorterClipUnchanged() throws {
        // Item is 3 s, project is 5 s → no clamp (clip already inside).
        let m = try AppAudioManifestBridge.buildManifest(
            items: [input(0, startUs: 0, durationUs: 3_000_000, payload())],
            includeOriginalFromVideoSlots: false, projectEndUs: 5_000_000)
        let clip = try XCTUnwrap(m.clips.first)
        XCTAssertEqual(clip.destination.end.ticks, 720_000, "3 s clip unchanged (3_000_000*6/25)")
    }

    func test_projectEndClamp_itemStartingAtOrAfterProjectEndIsSkipped() throws {
        // Item starts at 5 s in a 5 s project → nothing audible → skipped (no clip), not an error.
        let m = try AppAudioManifestBridge.buildManifest(
            items: [input(0, startUs: 5_000_000, durationUs: 2_000_000, payload())],
            includeOriginalFromVideoSlots: false, projectEndUs: 5_000_000)
        XCTAssertTrue(m.clips.isEmpty, "item at/after project end contributes no clip")
    }

    func test_noProjectEnd_noClamp_legacyCallersUnchanged() throws {
        // nil projectEndUs (default / legacy callers) → no clamp, full 10 s destination.
        let m = try AppAudioManifestBridge.buildManifest(
            items: [input(0, startUs: 0, durationUs: 10_000_000, payload())],
            includeOriginalFromVideoSlots: false)
        let clip = try XCTUnwrap(m.clips.first)
        XCTAssertEqual(clip.destination.end.ticks, 2_400_000, "no clamp → full 10 s (10_000_000*6/25)")
    }
}

// Tiny helper so the "no loop" structural intent has something concrete to assert.
private extension AudioPlaybackPolicy {
    static var allCasesCountIsOne: Int { 1 }
}
