import XCTest
@testable import AnimiEngineCore

/// Slice-004 Stage C — bounded PCM preparation model tests.
///
/// `PreparedAudioBuffer` (metadata only) + `AudioChunkPreparer` (injected contract). A deterministic
/// fake preparer cuts a bounded chunk with an opaque payload handle — no samples, no I/O, no
/// AVFoundation. Boundedness is fail-closed and the injected max is never a hardcoded constant.
final class AudioChunkPreparationTests: XCTestCase {

    // MARK: - Builders

    /// A segment whose destination is the half-open sample range `[start, end)`.
    private func segment(
        destStart: Int64,
        destEnd: Int64,
        muted: Bool = false,
        gain: AudioGain = .unity,
        sourceSampleRate: Int64 = 48_000,
        layout: AudioChannelLayoutDescriptor = .stereo,
        stream: String = "stream-1"
    ) throws -> AudioSegmentPlan {
        AudioSegmentPlan(
            clipID: try AudioClipID("c1"),
            sourceID: try AudioSourceID("s1"),
            trackID: try AudioTrackID("t1"),
            role: .music,
            destinationSamples: AudioSampleRange(uncheckedStart: destStart, end: destEnd),
            sourceStart: try RationalSourceTime(numerator: 0, denominator: 1),
            sourceEnd: try RationalSourceTime(numerator: 1, denominator: 1),
            effectiveTrim: try RationalSourceRange(
                start: try RationalSourceTime(numerator: 0, denominator: 1),
                end: try RationalSourceTime(numerator: 1, denominator: 1)
            ),
            isMuted: muted,
            gain: gain,
            sourceSampleRate: sourceSampleRate,
            channelLayout: layout,
            streamIdentity: try AudioStreamIdentity(stream),
            sceneID: nil
        )
    }

    private func request(
        seg: AudioSegmentPlan,
        revision: Int64 = 1,
        epoch: Int64 = 1,
        requestID: Int64 = 1,
        chunkStart: Int64,
        chunkEnd: Int64,
        maxChunkSamples: Int64 = 1_024
    ) -> AudioChunkRequest {
        AudioChunkRequest(
            segment: seg,
            revision: ProjectRevision(raw: revision),
            epoch: PlaybackEpoch(raw: epoch),
            request: AudioRequestID(raw: requestID),
            chunkRange: AudioSampleRange(uncheckedStart: chunkStart, end: chunkEnd),
            maxChunkSamples: maxChunkSamples
        )
    }

    // MARK: - Deterministic fake preparer (no AVFoundation, no I/O)

    private struct FakePreparer: AudioChunkPreparer {
        func prepare(_ request: AudioChunkRequest) throws -> PreparedAudioBuffer {
            let validated = try AudioChunkBounds.validate(request)
            return try PreparedAudioBuffer(
                revision: request.revision,
                epoch: request.epoch,
                request: request.request,
                sourceID: request.segment.sourceID,
                chunkRange: validated,
                streamIdentity: request.segment.streamIdentity,
                sourceSampleRate: request.segment.sourceSampleRate,
                channelLayout: request.segment.channelLayout,
                isMuted: request.segment.isMuted,
                gain: request.segment.gain,
                payload: try PreparedAudioPayloadHandle(
                    identifier: "pcm:\(request.segment.sourceID.raw):\(validated.start)-\(validated.end)")
            )
        }
    }

    // MARK: - Identity preservation

    func testPreparedBufferPreservesIdentityTupleExactly() throws {
        let seg = try segment(destStart: 0, destEnd: 1_000)
        let req = request(seg: seg, revision: 7, epoch: 9, requestID: 3, chunkStart: 100, chunkEnd: 200)
        let buf = try FakePreparer().prepare(req)

        XCTAssertEqual(buf.revision, ProjectRevision(raw: 7))
        XCTAssertEqual(buf.epoch, PlaybackEpoch(raw: 9))
        XCTAssertEqual(buf.request, AudioRequestID(raw: 3))
        XCTAssertEqual(buf.sourceID, try AudioSourceID("s1"))
        XCTAssertEqual(buf.chunkRange, AudioSampleRange(uncheckedStart: 100, end: 200))
        XCTAssertEqual(buf.frameCount, 100)
    }

    func testRangeDescriptorBridgesToAdmissionDescriptor() throws {
        let seg = try segment(destStart: 0, destEnd: 1_000)
        let req = request(seg: seg, revision: 2, epoch: 5, requestID: 8, chunkStart: 10, chunkEnd: 50)
        let buf = try FakePreparer().prepare(req)
        let desc = buf.rangeDescriptor

        XCTAssertEqual(desc.revision, ProjectRevision(raw: 2))
        XCTAssertEqual(desc.epoch, PlaybackEpoch(raw: 5))
        XCTAssertEqual(desc.request, AudioRequestID(raw: 8))
        XCTAssertEqual(desc.source, try AudioSourceID("s1"))
        XCTAssertEqual(desc.sampleRange, AudioSampleRange(uncheckedStart: 10, end: 50))
    }

    // MARK: - Inequality where relevant

    func testBuffersDifferByEpochRevisionRequestSourceRange() throws {
        let seg = try segment(destStart: 0, destEnd: 1_000)
        let segOther = try segment(destStart: 0, destEnd: 1_000, stream: "stream-1")
        let base = try FakePreparer().prepare(
            request(seg: seg, revision: 1, epoch: 1, requestID: 1, chunkStart: 0, chunkEnd: 100))

        let diffEpoch = try FakePreparer().prepare(
            request(seg: seg, revision: 1, epoch: 2, requestID: 1, chunkStart: 0, chunkEnd: 100))
        XCTAssertNotEqual(base, diffEpoch)

        let diffRevision = try FakePreparer().prepare(
            request(seg: seg, revision: 2, epoch: 1, requestID: 1, chunkStart: 0, chunkEnd: 100))
        XCTAssertNotEqual(base, diffRevision)

        let diffRequest = try FakePreparer().prepare(
            request(seg: seg, revision: 1, epoch: 1, requestID: 2, chunkStart: 0, chunkEnd: 100))
        XCTAssertNotEqual(base, diffRequest)

        let diffRange = try FakePreparer().prepare(
            request(seg: segOther, revision: 1, epoch: 1, requestID: 1, chunkStart: 0, chunkEnd: 200))
        XCTAssertNotEqual(base, diffRange)
    }

    func testEqualBuffersAreEqual() throws {
        let seg = try segment(destStart: 0, destEnd: 1_000)
        let a = try FakePreparer().prepare(
            request(seg: seg, revision: 1, epoch: 1, requestID: 1, chunkStart: 0, chunkEnd: 100))
        let b = try FakePreparer().prepare(
            request(seg: seg, revision: 1, epoch: 1, requestID: 1, chunkStart: 0, chunkEnd: 100))
        XCTAssertEqual(a, b)
    }

    // MARK: - Descriptor metadata carried exactly

    func testPreparedBufferCarriesDescriptorMetadataExactly() throws {
        let seg = try segment(
            destStart: 0, destEnd: 1_000, muted: true, gain: try AudioGain(raw: 250_000),
            sourceSampleRate: 44_100, layout: try .discrete(count: 6), stream: "stream-XYZ")
        let buf = try FakePreparer().prepare(
            request(seg: seg, chunkStart: 0, chunkEnd: 100))

        XCTAssertEqual(buf.streamIdentity, try AudioStreamIdentity("stream-XYZ"))
        XCTAssertEqual(buf.sourceSampleRate, 44_100)
        XCTAssertEqual(buf.channelLayout, try .discrete(count: 6))
        XCTAssertEqual(buf.channelLayout.channelCount, 6)
        XCTAssertTrue(buf.isMuted)
        XCTAssertEqual(buf.gain.raw, 250_000)
    }

    // MARK: - Fail-closed boundedness

    func testEmptyChunkRangeRejectedTyped() throws {
        let seg = try segment(destStart: 0, destEnd: 1_000)
        XCTAssertThrowsError(try FakePreparer().prepare(
            request(seg: seg, chunkStart: 100, chunkEnd: 100))) { error in
            XCTAssertEqual(error as? AudioChunkPreparationError, .emptyChunkRange)
        }
    }

    func testInvertedChunkRangeRejectedTyped() throws {
        let seg = try segment(destStart: 0, destEnd: 1_000)
        // build an inverted range via the internal init to test the defensive guard.
        let req = AudioChunkRequest(
            segment: seg,
            revision: ProjectRevision(raw: 1), epoch: PlaybackEpoch(raw: 1), request: AudioRequestID(raw: 1),
            chunkRange: AudioSampleRange(uncheckedStart: 200, end: 100),
            maxChunkSamples: 1_024)
        XCTAssertThrowsError(try FakePreparer().prepare(req)) { error in
            XCTAssertEqual(error as? AudioChunkPreparationError, .invertedChunkRange)
        }
    }

    func testChunkFullyOutsideDestinationRejected() throws {
        let seg = try segment(destStart: 100, destEnd: 200)
        XCTAssertThrowsError(try FakePreparer().prepare(
            request(seg: seg, chunkStart: 300, chunkEnd: 400))) { error in
            XCTAssertEqual(error as? AudioChunkPreparationError, .chunkOutsideSegmentDestination)
        }
    }

    func testChunkPartiallyOutsideDestinationRejectedFailClosed() throws {
        let seg = try segment(destStart: 100, destEnd: 200)
        // starts inside, ends past dest.end → fail-closed, NOT clipped.
        XCTAssertThrowsError(try FakePreparer().prepare(
            request(seg: seg, chunkStart: 150, chunkEnd: 250))) { error in
            XCTAssertEqual(error as? AudioChunkPreparationError, .chunkOutsideSegmentDestination)
        }
        // starts before dest.start → also fail-closed.
        XCTAssertThrowsError(try FakePreparer().prepare(
            request(seg: seg, chunkStart: 50, chunkEnd: 150))) { error in
            XCTAssertEqual(error as? AudioChunkPreparationError, .chunkOutsideSegmentDestination)
        }
    }

    func testWholeProjectRangeNotAcceptedAsOneUnboundedChunk() throws {
        // destination is large; the injected max forbids one giant chunk.
        let seg = try segment(destStart: 0, destEnd: 48_000 * 600) // 10 min @ 48 kHz
        XCTAssertThrowsError(try FakePreparer().prepare(
            request(seg: seg, chunkStart: 0, chunkEnd: 48_000 * 600, maxChunkSamples: 1_024))) { error in
            XCTAssertEqual(
                error as? AudioChunkPreparationError,
                .chunkExceedsMaxSize(requested: 48_000 * 600, max: 1_024))
        }
    }

    func testChunkExactlyMaxSizeAccepted() throws {
        let seg = try segment(destStart: 0, destEnd: 10_000)
        let buf = try FakePreparer().prepare(
            request(seg: seg, chunkStart: 0, chunkEnd: 1_024, maxChunkSamples: 1_024))
        XCTAssertEqual(buf.frameCount, 1_024)
    }

    func testNonPositiveMaxChunkSizeRejectedTyped() throws {
        let seg = try segment(destStart: 0, destEnd: 1_000)
        XCTAssertThrowsError(try FakePreparer().prepare(
            request(seg: seg, chunkStart: 0, chunkEnd: 100, maxChunkSamples: 0))) { error in
            XCTAssertEqual(error as? AudioChunkPreparationError, .invalidMaxChunkSize(0))
        }
    }

    // MARK: - Opaque payload

    func testEmptyPayloadHandleRejectedTyped() {
        XCTAssertThrowsError(try PreparedAudioPayloadHandle(identifier: "")) { error in
            XCTAssertEqual(error as? AudioChunkPreparationError, .invalidPreparedPayload)
        }
    }

    func testValueTypesAreSendable() {
        func requireSendable<T: Sendable>(_ type: T.Type) {}
        requireSendable(PreparedAudioBuffer.self)
        requireSendable(PreparedAudioPayloadHandle.self)
        requireSendable(AudioChunkRequest.self)
    }

    // MARK: - Direct PreparedAudioBuffer.init fail-closed (regression: no invalid buffer via public API)

    /// Builds a `PreparedAudioBuffer` directly (bypassing `AudioChunkBounds`) with overridable fields.
    private func directBuffer(
        chunkStart: Int64,
        chunkEnd: Int64,
        sourceSampleRate: Int64 = 48_000
    ) throws -> PreparedAudioBuffer {
        try PreparedAudioBuffer(
            revision: ProjectRevision(raw: 1),
            epoch: PlaybackEpoch(raw: 1),
            request: AudioRequestID(raw: 1),
            sourceID: try AudioSourceID("s1"),
            chunkRange: AudioSampleRange(uncheckedStart: chunkStart, end: chunkEnd),
            streamIdentity: try AudioStreamIdentity("stream-1"),
            sourceSampleRate: sourceSampleRate,
            channelLayout: .stereo,
            isMuted: false,
            gain: .unity,
            payload: try PreparedAudioPayloadHandle(identifier: "pcm:s1:0-1"))
    }

    func testDirectInitRejectsEmptyChunkRange() {
        XCTAssertThrowsError(try directBuffer(chunkStart: 100, chunkEnd: 100)) { error in
            XCTAssertEqual(error as? AudioChunkPreparationError, .emptyChunkRange)
        }
    }

    func testDirectInitRejectsInvertedChunkRange() {
        // inverted via the internal unchecked AudioSampleRange init.
        XCTAssertThrowsError(try directBuffer(chunkStart: 200, chunkEnd: 100)) { error in
            XCTAssertEqual(error as? AudioChunkPreparationError, .invertedChunkRange)
        }
    }

    func testDirectInitRejectsNonPositiveSourceSampleRate() {
        XCTAssertThrowsError(try directBuffer(chunkStart: 0, chunkEnd: 100, sourceSampleRate: 0)) { error in
            XCTAssertEqual(error as? AudioChunkPreparationError, .invalidPreparedSourceSampleRate(0))
        }
        XCTAssertThrowsError(
            try directBuffer(chunkStart: 0, chunkEnd: 100, sourceSampleRate: -48_000)) { error in
            XCTAssertEqual(
                error as? AudioChunkPreparationError, .invalidPreparedSourceSampleRate(-48_000))
        }
    }

    func testValidDirectInitStillPreservesIdentityAndMetadata() throws {
        let buf = try PreparedAudioBuffer(
            revision: ProjectRevision(raw: 4),
            epoch: PlaybackEpoch(raw: 6),
            request: AudioRequestID(raw: 8),
            sourceID: try AudioSourceID("s2"),
            chunkRange: AudioSampleRange(uncheckedStart: 10, end: 60),
            streamIdentity: try AudioStreamIdentity("stream-2"),
            sourceSampleRate: 44_100,
            channelLayout: try .discrete(count: 6),
            isMuted: true,
            gain: try AudioGain(raw: 250_000),
            payload: try PreparedAudioPayloadHandle(identifier: "pcm:s2:10-60"))

        XCTAssertEqual(buf.revision, ProjectRevision(raw: 4))
        XCTAssertEqual(buf.epoch, PlaybackEpoch(raw: 6))
        XCTAssertEqual(buf.request, AudioRequestID(raw: 8))
        XCTAssertEqual(buf.sourceID, try AudioSourceID("s2"))
        XCTAssertEqual(buf.chunkRange, AudioSampleRange(uncheckedStart: 10, end: 60))
        XCTAssertEqual(buf.frameCount, 50)
        XCTAssertEqual(buf.streamIdentity, try AudioStreamIdentity("stream-2"))
        XCTAssertEqual(buf.sourceSampleRate, 44_100)
        XCTAssertEqual(buf.channelLayout, try .discrete(count: 6))
        XCTAssertTrue(buf.isMuted)
        XCTAssertEqual(buf.gain.raw, 250_000)
    }

    /// `AudioChunkBounds` still owns the checks the buffer init deliberately does NOT do (destination
    /// containment and the injected max) — the buffer init only enforces self-contained invariants.
    func testAudioChunkBoundsStillOwnsDestinationAndMaxChecks() throws {
        let seg = try segment(destStart: 100, destEnd: 200)
        // destination containment is rejected by AudioChunkBounds (a self-contained-valid range that is
        // outside the segment).
        XCTAssertThrowsError(try AudioChunkBounds.validate(
            request(seg: seg, chunkStart: 300, chunkEnd: 400))) { error in
            XCTAssertEqual(error as? AudioChunkPreparationError, .chunkOutsideSegmentDestination)
        }
        // injected max is rejected by AudioChunkBounds.
        XCTAssertThrowsError(try AudioChunkBounds.validate(
            request(seg: seg, chunkStart: 100, chunkEnd: 200, maxChunkSamples: 10))) { error in
            XCTAssertEqual(
                error as? AudioChunkPreparationError, .chunkExceedsMaxSize(requested: 100, max: 10))
        }
        // but that same self-contained-valid range builds fine as a direct buffer.
        XCTAssertNoThrow(try directBuffer(chunkStart: 100, chunkEnd: 200))
    }
}
