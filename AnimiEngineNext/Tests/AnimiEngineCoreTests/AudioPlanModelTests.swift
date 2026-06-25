import XCTest
@testable import AnimiEngineCore

/// Slice-002 Stage B — pure audio value-model construction, equality, and basic invariants. No
/// builder/evaluator/segment-cutting logic is exercised here (those are Stage C).
final class AudioPlanModelTests: XCTestCase {

    // MARK: - AudioStreamIdentity

    func testStreamIdentityRejectsEmpty() {
        XCTAssertThrowsError(try AudioStreamIdentity("")) {
            XCTAssertEqual($0 as? AudioEvaluationError, .invalidAudioStreamIdentity)
        }
    }

    func testStreamIdentityAcceptsNonEmptyAndIsEquatable() throws {
        XCTAssertEqual(try AudioStreamIdentity("stream-A"), try AudioStreamIdentity("stream-A"))
        XCTAssertNotEqual(try AudioStreamIdentity("stream-A"), try AudioStreamIdentity("stream-B"))
    }

    // MARK: - AudioChannelLayoutDescriptor

    func testMonoHasChannelCountOne() {
        XCTAssertEqual(AudioChannelLayoutDescriptor.mono.kind, .mono)
        XCTAssertEqual(AudioChannelLayoutDescriptor.mono.channelCount, 1)
    }

    func testStereoHasChannelCountTwo() {
        XCTAssertEqual(AudioChannelLayoutDescriptor.stereo.kind, .stereo)
        XCTAssertEqual(AudioChannelLayoutDescriptor.stereo.channelCount, 2)
    }

    func testDiscretePositiveConstructsAndPreservesCount() throws {
        let six = try AudioChannelLayoutDescriptor.discrete(count: 6)
        XCTAssertEqual(six.kind, .discrete)
        XCTAssertEqual(six.channelCount, 6)
        // Equatable through the checked constructor (no direct unchecked path exists).
        XCTAssertEqual(six, try AudioChannelLayoutDescriptor.discrete(count: 6))
        XCTAssertNotEqual(six, try AudioChannelLayoutDescriptor.discrete(count: 5))
    }

    func testChannelLayoutRejectsDiscreteNonPositive() {
        XCTAssertThrowsError(try AudioChannelLayoutDescriptor.discrete(count: 0)) {
            XCTAssertEqual($0 as? AudioEvaluationError, .invalidAudioChannelLayout)
        }
        XCTAssertThrowsError(try AudioChannelLayoutDescriptor.discrete(count: -3)) {
            XCTAssertEqual($0 as? AudioEvaluationError, .invalidAudioChannelLayout)
        }
    }

    // Invalid discrete counts are unrepresentable: the only public discrete builder is the throwing
    // `discrete(count:)` above, and there is no public unchecked initializer to bypass it. (Compile-time
    // proof: a direct `AudioChannelLayoutDescriptor(kind: .discrete, channelCount: 0)` would not build —
    // the memberwise/`init` is private — so no test can construct one.)

    // MARK: - AudioPlan

    func testAudioPlanAllowsEmptySegments() throws {
        let plan = AudioPlan(sampleInterval: try sampleRange(0, 0), segments: [])
        XCTAssertTrue(plan.segments.isEmpty)
        XCTAssertEqual(plan, AudioPlan(sampleInterval: try sampleRange(0, 0), segments: []))
    }

    func testAudioPlanCarriesSegmentsAndIsEquatable() throws {
        let seg = try segment(muted: false)
        let plan = AudioPlan(sampleInterval: try sampleRange(0, 100), segments: [seg])
        XCTAssertEqual(plan.segments.count, 1)
        XCTAssertEqual(plan, AudioPlan(sampleInterval: try sampleRange(0, 100), segments: [seg]))
    }

    // MARK: - Muted segment preserved (lead decision: keep, isMuted = true)

    func testMutedSegmentIsRepresentableAndPreserved() throws {
        let muted = try segment(muted: true)
        XCTAssertTrue(muted.isMuted)
        let plan = AudioPlan(sampleInterval: try sampleRange(0, 100), segments: [muted])
        XCTAssertTrue(plan.segments[0].isMuted, "muted segment must be kept, not dropped")
    }

    // MARK: - Bindings

    func testGlobalBindingIsRepresentable() throws {
        let clip = try clip(binding: .global)
        XCTAssertEqual(clip.binding, .global)
    }

    func testVideoLayerBindingCarriesSceneIDAndSourceMapping() throws {
        let mapping = try sourceMapping()
        let scene = try SceneInstanceID("sceneA")
        let clip = try clip(binding: .videoLayer(sceneID: scene, sourceMapping: mapping))
        guard case .videoLayer(let sid, let m) = clip.binding else { return XCTFail("not videoLayer") }
        XCTAssertEqual(sid, scene)
        XCTAssertEqual(m, mapping)
    }

    // MARK: - Descriptor

    func testDescriptorCarriesTypedIdentityRateAndLayout() throws {
        let d = ResolvedAudioSourceDescriptor(
            sourceID: try AudioSourceID("s1"),
            streamIdentity: try AudioStreamIdentity("stream-1"),
            sourceDuration: try RationalSourceTime(numerator: 600, denominator: 1),
            sampleRate: 44_100,
            channelLayout: .stereo
        )
        XCTAssertEqual(d.streamIdentity, try AudioStreamIdentity("stream-1"))
        XCTAssertEqual(d.sampleRate, 44_100)
        XCTAssertEqual(d.channelLayout, .stereo)
        XCTAssertEqual(d, ResolvedAudioSourceDescriptor(
            sourceID: try AudioSourceID("s1"), streamIdentity: try AudioStreamIdentity("stream-1"),
            sourceDuration: try RationalSourceTime(numerator: 600, denominator: 1),
            sampleRate: 44_100, channelLayout: .stereo
        ))
    }

    // MARK: - AudioWindowScene / window

    func testWindowSceneCarriesOptionalFollowingBoundary() throws {
        let final = AudioWindowScene(
            sceneID: try SceneInstanceID("b"), sceneStart: try ProjectTime(ticks: 1000),
            nominalDuration: try TickDuration(ticks: 500), timelineSpan: try TickDuration(ticks: 500),
            followingBoundary: nil, followingTransition: nil
        )
        XCTAssertNil(final.followingBoundary)
        XCTAssertNil(final.followingTransition)
    }

    func testEvaluationWindowConstructsAndIsEquatable() throws {
        let track = ResolvedAudioTrack(trackID: try AudioTrackID("t1"), role: .videoLayer, order: 0)
        let window = AudioEvaluationWindow(
            coverage: try range(0, 1000), projectDuration: try TickDuration(ticks: 1000),
            scenes: [], tracks: [track], clips: [try clip(binding: .global)]
        )
        XCTAssertEqual(window.tracks.first?.order, 0)
        XCTAssertEqual(window, AudioEvaluationWindow(
            coverage: try range(0, 1000), projectDuration: try TickDuration(ticks: 1000),
            scenes: [], tracks: [track], clips: [try clip(binding: .global)]
        ))
    }

    // MARK: - No Float/Double in the new Audio source files

    func testNoFloatingPointInAudioSources() throws {
        // Locate the package's Sources/AnimiEngineCore/Audio dir relative to this test file.
        // #filePath = .../AnimiEngineNext/Tests/AnimiEngineCoreTests/AudioPlanModelTests.swift
        let thisFile = URL(fileURLWithPath: #filePath)
        let packageRoot = thisFile
            .deletingLastPathComponent()   // AnimiEngineCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // AnimiEngineNext (package root)
        let audioDir = packageRoot
            .appendingPathComponent("Sources/AnimiEngineCore/Audio", isDirectory: true)

        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "no Audio/*.swift found at \(audioDir.path)")

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for banned in ["Float", "Double", "Decimal", "import AVFoundation", "import AVFAudio"] {
                XCTAssertFalse(
                    text.contains(banned),
                    "\(file.lastPathComponent) must not reference \(banned) (integer/rational only)"
                )
            }
        }
    }

    // MARK: - Helpers

    /// A half-open 48 kHz sample range. `start == end` is the valid EMPTY range (uses the
    /// `@testable` internal init; `from(projectTicks:)` requires a non-empty project range).
    private func sampleRange(_ s: Int64, _ e: Int64) throws -> AudioSampleRange {
        AudioSampleRange(uncheckedStart: s, end: e)
    }

    private func range(_ s: Int64, _ e: Int64) throws -> ProjectTimeRange {
        try ProjectTimeRange(start: try ProjectTime(ticks: s), end: try ProjectTime(ticks: e))
    }

    private func sourceMapping() throws -> SourceTimeMapping {
        SourceTimeMapping(
            trimRange: try RationalSourceRange(
                start: try RationalSourceTime(numerator: 0, denominator: 1),
                end: try RationalSourceTime(numerator: 600, denominator: 1)
            ),
            nativeTimescale: try SourceTimescale(unitsPerSecond: 600),
            rate: try PlaybackRate(numerator: 1, denominator: 1)
        )
    }

    private func clip(binding: AudioClipBinding) throws -> ResolvedAudioClip {
        ResolvedAudioClip(
            clipID: try AudioClipID("c1"), trackID: try AudioTrackID("t1"), sourceID: try AudioSourceID("s1"),
            role: binding == .global ? .music : .videoLayer, isMuted: false, gain: .unity,
            destination: try range(0, 240_000),
            sourceTrim: try RationalSourceRange(
                start: try RationalSourceTime(numerator: 0, denominator: 1),
                end: try RationalSourceTime(numerator: 1, denominator: 1)
            ),
            playbackPolicy: .once, binding: binding,
            sourceDescriptor: ResolvedAudioSourceDescriptor(
                sourceID: try AudioSourceID("s1"), streamIdentity: try AudioStreamIdentity("stream-1"),
                sourceDuration: try RationalSourceTime(numerator: 600, denominator: 1),
                sampleRate: 48_000, channelLayout: .stereo
            )
        )
    }

    private func segment(muted: Bool) throws -> AudioSegmentPlan {
        AudioSegmentPlan(
            clipID: try AudioClipID("c1"), sourceID: try AudioSourceID("s1"), trackID: try AudioTrackID("t1"),
            role: .music,
            destinationSamples: try AudioSampleRange.from(projectTicks: try range(0, 100)),
            sourceStart: try RationalSourceTime(numerator: 0, denominator: 1),
            sourceEnd: try RationalSourceTime(numerator: 1, denominator: 1),
            effectiveTrim: try RationalSourceRange(
                start: try RationalSourceTime(numerator: 0, denominator: 1),
                end: try RationalSourceTime(numerator: 1, denominator: 1)
            ),
            isMuted: muted, gain: .unity, sourceSampleRate: 48_000, channelLayout: .stereo,
            streamIdentity: try AudioStreamIdentity("stream-1"), sceneID: nil
        )
    }
}
