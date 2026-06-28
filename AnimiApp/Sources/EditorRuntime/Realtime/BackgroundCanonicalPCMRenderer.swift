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

        #if DEBUG
        // Stage-8 render timing (DEBUG-only, behind DebugMemoryDiagnostics). Total render elapsed + per-source
        // decode elapsed; no per-sample logs. No behavior change. Marker: `preview.audio.stage8.render.*`.
        let s8RenderBegin = DispatchTime.now().uptimeNanoseconds
        #endif

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

            // 3b. STAGE-8.1 S8 FIX — clamp the decode to the canonical source end. The plan's destination
            //     intersection can map a chunk that extends PAST `segment.sourceEnd` (the source's audio
            //     genuinely ended), which made the decoder hit end-of-track and short-read. The canonical
            //     truth is `sourceEnd`: never ask for source frames beyond it. Available frames =
            //     floor( (sourceEnd − sourceStartForChunk) seconds × 48000 ), exact integer/rational math.
            let decodeFrameCount = try Self.framesAvailable(
                from: sourceStartForChunk, to: segment.sourceEnd,
                requested: frameCount, sourceIDRaw: segment.sourceID.raw)
            // The source has ended at or before this chunk's start → it contributes nothing here.
            guard decodeFrameCount > 0 else { continue }

            // 4. Decode the AVAILABLE frames (≤ frameCount) mono 48 kHz Float32 (raw; pre-gain/mute).
            let decodeRequest = CanonicalPCMAssetDecodeRequest(
                source: resolved,
                sourceIDRaw: segment.sourceID.raw,
                sourceStart: sourceStartForChunk,
                frameCount: decodeFrameCount)
            #if DEBUG
            let s8DecodeBegin = DispatchTime.now().uptimeNanoseconds
            #endif
            let decoded = try await decoder.decodeMono48kFloat32(decodeRequest)
            #if DEBUG
            if MemoryDiagnostics.isEnabled {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - s8DecodeBegin) / 1_000_000.0
                MemoryDiagnostics.event("preview.audio.stage8.render.decode",
                    "source=\(segment.sourceID.raw) sourceStart=\(sourceStartForChunk.numerator)/\(sourceStartForChunk.denominator) "
                    + "frameCount=\(decodeFrameCount) intersectionFrames=\(frameCount) elapsedMs=\(String(format: "%.2f", ms))")
            }
            #endif
            guard decoded.count == decodeFrameCount else {
                throw AppRealtimeAudioIntegrationError.pcmRenderFailed(
                    reason: "source \(segment.sourceID.raw): decoder returned \(decoded.count) frames, expected \(decodeFrameCount)")
            }

            // 5. Frame to the FULL bounded chunk range: zeros outside the intersection, decoded inside.
            //    (Structural framing to the bounded chunk so every source's chunkRange == key.range — NOT
            //    "non-empty plan → silence": the decoded region carries real samples; the source is genuinely
            //    silent over the part of the chunk it does not cover, and the graph SUMS sources.)
            //    When `decodeFrameCount < frameCount` (the source ended inside this chunk), the available
            //    prefix is written and the TAIL stays silence — only the part beyond `sourceEnd` is silent.
            var samples = [Float32](repeating: 0, count: chunkSampleCount)
            guard let offset = Int(exactly: iStart - chunkStart), offset >= 0, offset + decodeFrameCount <= chunkSampleCount else {
                throw AppRealtimeAudioIntegrationError.pcmRenderFailed(
                    reason: "source \(segment.sourceID.raw): intersection offset \(iStart - chunkStart) out of chunk bounds")
            }
            for j in 0..<decodeFrameCount {
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

        #if DEBUG
        if MemoryDiagnostics.isEnabled {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - s8RenderBegin) / 1_000_000.0
            MemoryDiagnostics.event("preview.audio.stage8.render.total",
                "range=\(request.range.start)..<\(request.range.end) segments=\(request.plan.segments.count) "
                + "sources=\(sources.count) elapsedMs=\(String(format: "%.2f", ms))")
        }
        #endif

        return try CanonicalPCMChunk(key: key, sources: sources)
    }

    /// STAGE-8.1 S8 FIX — the number of 48 kHz frames available from `sourceStart` up to the canonical
    /// `sourceEnd`, clamped to `requested`. EXACT integer/rational math (no Double, no µs truncation):
    ///
    ///   available_seconds = sourceEnd − sourceStart      (RationalSourceTime, reduced, denom > 0)
    ///   availableFrames    = floor( available.numerator × 48000 / available.denominator )
    ///
    /// Returns:
    ///   - 0 if `sourceStart >= sourceEnd` (the source has already ended at/before this chunk → silence);
    ///   - `min(requested, availableFrames)` otherwise (decode only what truly exists, never past sourceEnd).
    /// Fail-closed (typed `pcmRenderFailed`) on any overflow / non-representable intermediate — never a
    /// silent wrong count.
    static func framesAvailable(
        from sourceStart: RationalSourceTime, to sourceEnd: RationalSourceTime,
        requested: Int, sourceIDRaw: String
    ) throws -> Int {
        // Source already ended at/before the chunk start → nothing to decode (not an error).
        guard sourceStart < sourceEnd else { return 0 }
        let available: RationalSourceTime
        do {
            available = try sourceEnd.subtracting(sourceStart)
        } catch {
            throw AppRealtimeAudioIntegrationError.pcmRenderFailed(
                reason: "source \(sourceIDRaw): sourceEnd − sourceStart not representable")
        }
        // available > 0 here (sourceStart < sourceEnd) and denominator > 0 (reduced rational invariant).
        // availableFrames = floor(numerator × 48000 / denominator); guard the multiply against Int64 overflow.
        let scaled = available.numerator.multipliedReportingOverflow(by: AudioSampleGrid.samplesPerSecond)
        guard !scaled.overflow else {
            throw AppRealtimeAudioIntegrationError.pcmRenderFailed(
                reason: "source \(sourceIDRaw): available-frames numerator overflow "
                      + "(\(available.numerator)×\(AudioSampleGrid.samplesPerSecond))")
        }
        let availableFrames64 = scaled.partialValue / available.denominator   // floor for non-negative operands
        guard let availableFrames = Int(exactly: availableFrames64) else {
            throw AppRealtimeAudioIntegrationError.pcmRenderFailed(
                reason: "source \(sourceIDRaw): available frames \(availableFrames64) not representable as Int")
        }
        return min(requested, availableFrames)
    }
}
