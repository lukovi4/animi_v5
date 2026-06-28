import Foundation
import AnimiEngineCore

/// Slice-005 Stage 3 — the background/offline `CanonicalPCMRenderer`.
///
/// Pure segment/range math + an injected `CanonicalPCMAssetDecoder`. It intersects each `AudioSegmentPlan`
/// with the requested bounded `AudioSampleRange`, computes the EXACT rational source start (integer/rational
/// only — no `Double`, no µs truncation), asks the decoder for exactly the intersection's frame count, and
/// frames each source to the full bounded chunk range (zeros outside the segment's intersection). It NEVER
/// applies gain/mute/mix/output — those metadata are carried into `PreparedAudioBuffer` for `PreviewAudioGraph`.
///
/// NO AVFoundation here. NO live-play dependency. Fail-closed: a non-empty plan that cannot be rendered
/// THROWS a typed error; it is never converted to `[]`/silence.
struct BackgroundCanonicalPCMRenderer: CanonicalPCMRenderer {

    let decoder: CanonicalPCMAssetDecoder

    init(decoder: CanonicalPCMAssetDecoder) {
        self.decoder = decoder
    }

    func render(_ request: CanonicalAudioRenderRequest) async throws -> CanonicalPCMChunk {
        // Rebuild the EXACT key the Stage-2 pipeline/cache requested (the renderer protocol receives only the
        // request). The cache validates `chunk.key == requestedKey`.
        let key = try CanonicalPCMRenderKey(
            revision: request.revision,
            epoch: request.epoch,
            planIdentity: CanonicalAudioPlanIdentity.string(for: request.plan),
            range: request.range)

        // Empty plan is legitimate silence (the Stage-2 pipeline already short-circuits this before the
        // cache; defensive here). An empty-sources chunk satisfies the Stage-1 identity gate.
        if request.plan.segments.isEmpty {
            return try CanonicalPCMChunk(key: key, sources: [])
        }

        let chunkStart = request.range.start
        // Fail-closed Int64 → Int (never trap on non-representable counts/offsets — 32-bit safety + intent).
        guard let chunkSampleCount = Int(exactly: request.range.sampleCount) else {
            throw AppRealtimeAudioIntegrationError.pcmRenderFailed(
                reason: "chunk sample count \(request.range.sampleCount) is not representable as Int")
        }
        // Deterministic per-render AudioRequestID sequence (metadata identity; not a wall-clock value).
        var requestIDs = MonotonicRequestIDAllocator()

        var sources: [PreviewMixSource] = []
        for segment in request.plan.segments {
            // 1. Intersect the segment destination with the requested bounded range (both half-open 48 kHz).
            let iStart = max(segment.destinationSamples.start, request.range.start)
            let iEnd = min(segment.destinationSamples.end, request.range.end)
            guard iEnd > iStart else { continue }   // no overlap → contributes nothing to this chunk
            guard let frameCount = Int(exactly: iEnd - iStart) else {
                throw AppRealtimeAudioIntegrationError.pcmRenderFailed(
                    reason: "source \(segment.sourceID.raw): intersection count \(iEnd - iStart) not representable as Int")
            }

            // 2. Resolve the source URL (fail-closed on missing).
            guard let resolved = request.resolvedSourcesByID[segment.sourceID.raw] else {
                throw AppRealtimeAudioIntegrationError.mediaUnavailable(sourceRaw: segment.sourceID.raw)
            }

            // 3. EXACT source start for the first intersected frame:
            //    segment.sourceStart + (iStart - destStart) / 48000  (exact rational; no Double / no µs).
            let deltaFrames = iStart - segment.destinationSamples.start
            let sourceStartForChunk: RationalSourceTime
            do {
                let advance = try RationalSourceTime(
                    numerator: deltaFrames, denominator: AudioSampleGrid.samplesPerSecond)
                sourceStartForChunk = try segment.sourceStart.adding(advance)
            } catch {
                throw AppRealtimeAudioIntegrationError.sourceStartNotRepresentable(
                    detail: "source \(segment.sourceID.raw): advance \(deltaFrames)/\(AudioSampleGrid.samplesPerSecond) overflowed")
            }

            // 4. Decode EXACTLY frameCount mono 48 kHz Float32 frames (raw; pre-gain/mute).
            let decodeRequest = CanonicalPCMAssetDecodeRequest(
                source: resolved,
                sourceIDRaw: segment.sourceID.raw,
                sourceStart: sourceStartForChunk,
                frameCount: frameCount)
            let decoded = try await decoder.decodeMono48kFloat32(decodeRequest)
            guard decoded.count == frameCount else {
                throw AppRealtimeAudioIntegrationError.pcmRenderFailed(
                    reason: "source \(segment.sourceID.raw): decoder returned \(decoded.count) frames, expected \(frameCount)")
            }

            // 5. Frame to the FULL bounded chunk range: zeros outside the intersection, decoded inside.
            //    (Structural framing to the bounded chunk so every source's chunkRange == key.range — NOT
            //    "non-empty plan → silence": the decoded region carries real samples; the source is genuinely
            //    silent over the part of the chunk it does not cover, and the graph SUMS sources.)
            var samples = [Float32](repeating: 0, count: chunkSampleCount)
            guard let offset = Int(exactly: iStart - chunkStart), offset >= 0, offset + frameCount <= chunkSampleCount else {
                throw AppRealtimeAudioIntegrationError.pcmRenderFailed(
                    reason: "source \(segment.sourceID.raw): intersection offset \(iStart - chunkStart) out of chunk bounds")
            }
            for j in 0..<frameCount {
                samples[offset + j] = decoded[j]
            }

            // 6. Buffer metadata carries (does NOT apply) gain/mute/stream/rate/layout. chunkRange == key.range.
            let buffer = try PreparedAudioBuffer(
                revision: request.revision,
                epoch: request.epoch,
                request: requestIDs.nextAudioRequest(),
                sourceID: segment.sourceID,
                chunkRange: request.range,
                streamIdentity: segment.streamIdentity,
                sourceSampleRate: segment.sourceSampleRate,
                channelLayout: segment.channelLayout,
                isMuted: segment.isMuted,
                gain: segment.gain,
                payload: try PreparedAudioPayloadHandle(
                    identifier: "bgpcm:\(segment.sourceID.raw):\(request.range.start)-\(request.range.end)"))
            sources.append(PreviewMixSource(buffer: buffer, samples: samples))
        }

        return try CanonicalPCMChunk(key: key, sources: sources)
    }
}
