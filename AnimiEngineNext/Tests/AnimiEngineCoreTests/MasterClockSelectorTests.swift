import XCTest
@testable import AnimiEngineCore

/// Slice-003 Stage B — pure master-clock selection (ADR-006 §3).
///
/// Proves the selection rule over the EXISTING `AudioEvaluator` semantics (no duplicated audio mapping
/// math): unmuted canonical audio in the remaining range ⇒ `.audioSample`; otherwise (no audio,
/// muted-only, audio outside the range, or no covered interval) ⇒ `.monotonicHost`. Audio that begins
/// after an initial silent gap still selects audio.
final class MasterClockSelectorTests: XCTestCase {

    // MARK: - No audio / empty window ⇒ host

    func testNoAudioWindowSelectsHost() throws {
        // A window with a track but no clips ⇒ zero segments ⇒ host.
        let w = try window(tracks: [try track("t1")], clips: [])
        XCTAssertEqual(try select(w, 0, 240_000), .monotonicHost)
    }

    func testWindowWithNoTracksOrClipsSelectsHost() throws {
        let w = try window(tracks: [], clips: [])
        XCTAssertEqual(try select(w, 0, 240_000), .monotonicHost)
    }

    // MARK: - Audio segment in remaining range ⇒ audio

    func testUnmutedAudioInRemainingRangeSelectsAudio() throws {
        let w = try window(tracks: [try track("t1")], clips: [try globalClip("c1", dest: (0, 240_000))])
        XCTAssertEqual(try select(w, 0, 240_000), .audioSample)
    }

    // MARK: - Muted-only audio in remaining range ⇒ host

    func testMutedOnlyAudioSelectsHost() throws {
        let w = try window(tracks: [try track("t1")], clips: [try globalClip("c1", dest: (0, 240_000), muted: true)])
        // The segment IS emitted (muted segments are kept), but it is muted ⇒ host.
        XCTAssertEqual(try select(w, 0, 240_000), .monotonicHost)
    }

    // MARK: - Audio outside the remaining range ⇒ host

    func testAudioOutsideRemainingRangeSelectsHost() throws {
        // Clip plays only in [0, 120_000); the remaining range is [120_000, 240_000) ⇒ no segment ⇒ host.
        let w = try window(tracks: [try track("t1")], clips: [try globalClip("c1", dest: (0, 120_000))])
        XCTAssertEqual(try select(w, 120_000, 240_000), .monotonicHost)
    }

    // MARK: - Audio after a silent gap but still in remaining range ⇒ audio

    func testAudioAfterSilentGapWithinRemainingRangeSelectsAudio() throws {
        // Silent gap [0, 120_000); audio begins at 120_000. Remaining range covers the whole project, so
        // the post-gap audio is present ⇒ audio. (ADR-006 §3: an initial silent gap does not pick host.)
        let w = try window(tracks: [try track("t1")], clips: [try globalClip("c1", dest: (120_000, 240_000))])
        XCTAssertEqual(try select(w, 0, 240_000), .audioSample)
    }

    func testRemainingRangeStartingBeforeAudioStillSelectsAudio() throws {
        // Remaining range [60_000, 240_000) still includes the audio that starts at 120_000 ⇒ audio.
        let w = try window(tracks: [try track("t1")], clips: [try globalClip("c1", dest: (120_000, 240_000))])
        XCTAssertEqual(try select(w, 60_000, 240_000), .audioSample)
    }

    // MARK: - Remaining range outside coverage ⇒ host (degenerate / empty covered interval)

    func testRemainingRangeOutsideCoverageSelectsHost() throws {
        // Window covers [0, 240_000); remaining is entirely past coverage. No covered interval ⇒ host,
        // and the selector never calls the evaluator out of coverage.
        let w = try window(coverage: (0, 240_000), tracks: [try track("t1")],
                           clips: [try globalClip("c1", dest: (0, 240_000))])
        XCTAssertEqual(try select(w, 240_000, 480_000), .monotonicHost)
    }

    // MARK: - Mixed muted + unmuted in range ⇒ audio (any unmuted is enough)

    func testMixedMutedAndUnmutedSelectsAudio() throws {
        let w = try window(
            tracks: [try track("t1", order: 0), try track("t2", order: 1)],
            clips: [
                try globalClip("c1", track: "t1", source: "s1", dest: (0, 240_000), muted: true),
                try globalClip("c2", track: "t2", source: "s2", dest: (0, 240_000), muted: false),
            ]
        )
        XCTAssertEqual(try select(w, 0, 240_000), .audioSample)
    }

    // MARK: - Helpers

    private func select(_ w: AudioEvaluationWindow, _ s: Int64, _ e: Int64) throws -> MasterClockKind {
        try MasterClockSelector.select(window: w, remaining: try range(s, e))
    }

    private func window(
        coverage: (Int64, Int64) = (0, 240_000),
        projectDuration: Int64 = 240_000,
        tracks: [ResolvedAudioTrack],
        clips: [ResolvedAudioClip]
    ) throws -> AudioEvaluationWindow {
        AudioEvaluationWindow(
            coverage: try range(coverage.0, coverage.1),
            projectDuration: try TickDuration(ticks: projectDuration),
            scenes: [], tracks: tracks, clips: clips
        )
    }

    private func track(_ id: String, _ role: AudioSourceRole = .music, order: Int = 0) throws -> ResolvedAudioTrack {
        ResolvedAudioTrack(trackID: try AudioTrackID(id), role: role, order: order)
    }

    private func descriptor(_ sourceID: String) throws -> ResolvedAudioSourceDescriptor {
        ResolvedAudioSourceDescriptor(
            sourceID: try AudioSourceID(sourceID), streamIdentity: try AudioStreamIdentity("stream-\(sourceID)"),
            sourceDuration: try RationalSourceTime(numerator: 600, denominator: 1),
            sampleRate: 48_000, channelLayout: .stereo
        )
    }

    private func globalClip(
        _ id: String, track: String = "t1", source: String = "s1",
        dest: (Int64, Int64), muted: Bool = false
    ) throws -> ResolvedAudioClip {
        ResolvedAudioClip(
            clipID: try AudioClipID(id), trackID: try AudioTrackID(track), sourceID: try AudioSourceID(source),
            role: .music, isMuted: muted, gain: .unity,
            destination: try range(dest.0, dest.1), sourceTrim: try trim(0, 600),
            playbackPolicy: .once, binding: .global, sourceDescriptor: try descriptor(source)
        )
    }

    private func range(_ s: Int64, _ e: Int64) throws -> ProjectTimeRange {
        try ProjectTimeRange(start: try ProjectTime(ticks: s), end: try ProjectTime(ticks: e))
    }

    private func trim(_ startSeconds: Int64, _ endSeconds: Int64) throws -> RationalSourceRange {
        try RationalSourceRange(
            start: try RationalSourceTime(numerator: startSeconds, denominator: 1),
            end: try RationalSourceTime(numerator: endSeconds, denominator: 1)
        )
    }
}
