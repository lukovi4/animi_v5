/// The pure audio evaluator (ADR-012 §1.0a, §3). Consumes one immutable ``AudioEvaluationWindow`` and
/// an exact half-open project tick interval, and returns a deterministic immutable ``AudioPlan``.
///
/// Pure: no payload lookup, no source resolution, no I/O, no decode, no audio-framework dependency, no
/// clocks. All time math is exact integer ticks / exact rational source time (no floating-point types,
/// no approximation). The project→source correspondence reuses the SAME `SceneMediaClock.sceneMediaTime`
/// and `SourceTimeMapping.target(for:)` the video evaluator uses (audio never builds its own mapping).
public enum AudioEvaluator {

    public static func evaluate(
        window: AudioEvaluationWindow,
        range: ProjectTimeRange
    ) throws -> AudioPlan {
        // Requested range must lie within the window coverage (half-open endpoint containment).
        guard range.start >= window.coverage.start, range.end <= window.coverage.end else {
            throw AudioEvaluationError.audioWindowCoverageViolation
        }

        let sampleInterval = try AudioSampleRange.from(projectTicks: range)
        // An empty requested sample interval yields zero segments (valid, not an error).
        if sampleInterval.isEmpty {
            return AudioPlan(sampleInterval: sampleInterval, segments: [])
        }

        let trackOrder = Dictionary(uniqueKeysWithValues: window.tracks.map { ($0.trackID, $0.order) })
        let sceneByID = Dictionary(uniqueKeysWithValues: window.scenes.map { ($0.sceneID, $0) })

        var segments: [AudioSegmentPlan] = []
        for clip in window.clips {
            if let segment = try segment(for: clip, requested: range, sceneByID: sceneByID) {
                segments.append(segment)
            }
        }

        // Deterministic ordering: (track.order, destinationSamples.start, clipID.raw, sourceID.raw).
        segments.sort { lhs, rhs in
            let lo = trackOrder[lhs.trackID] ?? Int.max
            let ro = trackOrder[rhs.trackID] ?? Int.max
            if lo != ro { return lo < ro }
            if lhs.destinationSamples.start != rhs.destinationSamples.start {
                return lhs.destinationSamples.start < rhs.destinationSamples.start
            }
            if lhs.clipID.raw != rhs.clipID.raw { return lhs.clipID.raw < rhs.clipID.raw }
            return lhs.sourceID.raw < rhs.sourceID.raw
        }

        return AudioPlan(sampleInterval: sampleInterval, segments: segments)
    }

    // MARK: - Per-clip segment

    /// Builds at most one segment for a clip over the requested range, or `nil` (zero segments) when the
    /// clip is silent there. Muted clips that ARE audible are kept with `isMuted = true`.
    private static func segment(
        for clip: ResolvedAudioClip,
        requested: ProjectTimeRange,
        sceneByID: [SceneInstanceID: AudioWindowScene]
    ) throws -> AudioSegmentPlan? {
        // 1. Active destination = clip.destination ∩ requested (half-open). Empty → zero segments.
        guard let activeDest = intersection(clip.destination, requested) else { return nil }

        // 2. The affine project→source map for this clip (global 1/1 or the video layer's mapping),
        //    plus the role/scene-media context the video-layer map needs.
        let map = try AffineSourceMap(clip: clip, sceneByID: sceneByID)

        // 3. Source endpoints over the active destination (exact rational). The map is monotonic
        //    non-decreasing (rate >= 0), so [srcAtStart, srcAtEnd) bounds the source the clip would read.
        let srcAtStart = try map.source(atProjectTick: activeDest.start.ticks)
        let srcAtEnd = try map.source(atProjectTick: activeDest.end.ticks)

        // 4. Trim + `.once` gate (half-open). Audible source window = [srcAtStart, srcAtEnd) ∩ sourceTrim.
        //    `.once` is implicit: the source advances monotonically and we never loop or extend past the
        //    first end (the earlier of activeDest.end and the trim-end crossing).
        let trim = clip.sourceTrim
        let audibleSrcLo = maxRational(srcAtStart, trim.start)
        // Stage-9.2 fix: the audible source upper bound is the 3-way min of the mapped end, the trim end,
        // AND the source's REAL duration (`descriptor.sourceDuration`). A clip whose destination/trim maps
        // past the real audio track (e.g. a stretched video-original scene) must STOP at the real source
        // end, not read past it — otherwise the renderer's `segment.sourceEnd`-based clamp over-requests and
        // the decoder short-reads (S9.2). Because every downstream value (`destHiTick`, the final
        // `sourceEnd`) is derived from `audibleSrcHi`, clamping it here bounds `segment.sourceEnd` ≤
        // `sourceDuration` by construction. Exact rational; no validation loosened.
        let audibleSrcHi = minRational(minRational(srcAtEnd, trim.end), clip.sourceDescriptor.sourceDuration)
        // Empty audible source window (incl. a requested range entirely past `sourceDuration`) → zero segments.
        guard audibleSrcLo < audibleSrcHi else { return nil }

        // 5. Invert the audible source bounds back to EXACT project ticks to clip the destination.
        //    Lower bound rounds toward the start of audibility; upper bound is the first tick at which
        //    the source reaches `audibleSrcHi` (the `.once` / trim-end stop). Both are exact.
        let destLoTick = try map.firstProjectTick(sourceAtLeast: audibleSrcLo, notBefore: activeDest.start.ticks)
        let destHiTick = try map.firstProjectTick(sourceAtLeast: audibleSrcHi, notBefore: activeDest.start.ticks)
        let clippedLo = max(destLoTick, activeDest.start.ticks)
        let clippedHi = min(destHiTick, activeDest.end.ticks)
        guard clippedHi > clippedLo else { return nil }

        let audibleDest = try ProjectTimeRange(
            start: try ProjectTime(ticks: clippedLo), end: try ProjectTime(ticks: clippedHi)
        )
        let destinationSamples = try AudioSampleRange.from(projectTicks: audibleDest)
        // Two distinct ticks can collapse to one sample at the 48 kHz grid → legitimately empty segment.
        guard !destinationSamples.isEmpty else { return nil }

        // 6. Exact source bounds at the clipped destination endpoints (the audible sub-window).
        let sourceStart = try map.source(atProjectTick: clippedLo)
        let sourceEnd = try map.source(atProjectTick: clippedHi)
        let effectiveTrim = try RationalSourceRange(start: sourceStart, end: sourceEnd)

        return AudioSegmentPlan(
            clipID: clip.clipID, sourceID: clip.sourceID, trackID: clip.trackID, role: clip.role,
            destinationSamples: destinationSamples,
            sourceStart: sourceStart, sourceEnd: sourceEnd, effectiveTrim: effectiveTrim,
            isMuted: clip.isMuted, gain: clip.gain,
            // Conversion metadata copied EXACTLY from the resolved source descriptor — never synthesized.
            sourceSampleRate: clip.sourceDescriptor.sampleRate,
            channelLayout: clip.sourceDescriptor.channelLayout,
            streamIdentity: clip.sourceDescriptor.streamIdentity,
            sceneID: map.sceneID
        )
    }

    // MARK: - Interval helpers

    private static func intersection(_ a: ProjectTimeRange, _ b: ProjectTimeRange) -> ProjectTimeRange? {
        let loTicks = max(a.start.ticks, b.start.ticks)
        let hiTicks = min(a.end.ticks, b.end.ticks)
        guard hiTicks > loTicks else { return nil }
        // Both endpoints are valid project ticks already; reconstruct (end > start guaranteed).
        guard let lo = try? ProjectTime(ticks: loTicks), let hi = try? ProjectTime(ticks: hiTicks),
              let range = try? ProjectTimeRange(start: lo, end: hi) else { return nil }
        return range
    }

    private static func maxRational(_ a: RationalSourceTime, _ b: RationalSourceTime) -> RationalSourceTime {
        a < b ? b : a
    }
    private static func minRational(_ a: RationalSourceTime, _ b: RationalSourceTime) -> RationalSourceTime {
        a < b ? a : b
    }
}

/// The exact affine project→source map for one resolved clip (internal to the evaluator). It composes
/// `SceneMediaClock.sceneMediaTime` (video-layer) or the identity local clock (global) with the clip's
/// `SourceTimeMapping`, and inverts the trim/`.once` boundary back to an EXACT project tick using
/// integer 128-bit arithmetic — exact, no approximation.
private struct AffineSourceMap {
    /// `sourceTime(T) = mapping.target(for: localTicks(T))`, where `localTicks` is the scene-media
    /// clock (video-layer) or `T − destination.start` (global, with a synthesized 1/1 mapping).
    let mapping: SourceTimeMapping
    /// The project tick that corresponds to scene-local 0 for this clip's local clock.
    let baseProjectTick: Int64
    /// The scene-media role context (video-layer only); `nil` for global.
    let role: SceneMediaClock.SceneRole?
    let sceneStart: Int64
    let boundary: Int64?
    let sceneID: SceneInstanceID?

    init(clip: ResolvedAudioClip, sceneByID: [SceneInstanceID: AudioWindowScene]) throws {
        switch clip.binding {
        case .global:
            // Strict 1/1: synthesize a mapping whose trimRange.start is the clip's sourceTrim.start and
            // rate 1/1; the local clock is `T − destination.start`.
            self.mapping = SourceTimeMapping(
                trimRange: clip.sourceTrim,
                nativeTimescale: try SourceTimescale(unitsPerSecond: TickClock.ticksPerSecond),
                rate: PlaybackRate.oneToOne
            )
            self.baseProjectTick = clip.destination.start.ticks
            self.role = nil
            self.sceneStart = 0
            self.boundary = nil
            self.sceneID = nil
        case .videoLayer(let sceneID, let sourceMapping):
            guard let scene = sceneByID[sceneID] else {
                throw AudioEvaluationError.unknownAudioWindowScene(sceneID: sceneID.raw)
            }
            self.mapping = sourceMapping
            self.sceneStart = scene.sceneStart.ticks
            // Role: incoming iff this clip's destination sits inside the scene's incoming side of a
            // following/preceding boundary. Slice-1 validation forbids incoming destinations before the
            // boundary, and a video-audio clip is bound to exactly one scene-layer, so the canonical
            // role for source-time is `.sole` (continues at normal speed; outgoing post-roll is the same
            // T − sceneStart formula). The `.incoming` hold is realised by the destination constraint,
            // not by a separate source clock here.
            self.role = .sole
            self.boundary = scene.followingBoundary?.ticks
            self.baseProjectTick = scene.sceneStart.ticks
            self.sceneID = sceneID
        }
    }

    /// Exact source time at a project tick `T`.
    ///
    /// The scene-media clock is the shared `SceneMediaClock.sceneMediaTime`, but it requires
    /// `T >= sceneStart` for `.sole`/`.outgoing` (it measures `T − sceneStart`). A clip destination
    /// that precedes its own scene start maps to a HELD media clock (local 0) — the source does not
    /// advance, which collapses the audible window into silence. We realise that hold by clamping the
    /// local tick offset to `>= 0` (equivalent to the incoming pre-boundary hold), never throwing.
    func source(atProjectTick projectTick: Int64) throws -> RationalSourceTime {
        let localTicks: Int64
        if let role {
            if projectTick >= sceneStart {
                // Inside the scene's media domain: use the SHARED clock verbatim (audio reuses the
                // video evaluator's per-scene media time — never a separate audio mapping).
                let media = try SceneMediaClock.sceneMediaTime(
                    role: role,
                    at: try ProjectTime(ticks: projectTick),
                    sceneStart: try ProjectTime(ticks: sceneStart),
                    boundary: try boundary.map { try ProjectTime(ticks: $0) }
                )
                localTicks = media.ticks
            } else {
                // Before the scene start: the media clock is HELD at 0 (the same `0` floor as the
                // incoming pre-boundary hold). The source does not advance → silence by construction.
                localTicks = 0
            }
        } else {
            localTicks = max(0, projectTick - baseProjectTick)
        }
        return try mapping.target(for: ScenePlaybackTime(uncheckedTicks: localTicks))
    }

    /// The first project tick `>= notBefore` whose source time is `>= target`. EXACT and search-free.
    ///
    /// The map is affine: `source(base + local) = anchor + (rn/rd)·(local/240000)`, so the smallest
    /// `local` with `source >= target` is
    ///
    ///     local_min = ceil( (target − anchor) · rd · 240000 / rn )
    ///             = ceil( (P · (rd · 240000)) / (Q · rn) )    where (target − anchor) = P/Q, P >= 0.
    ///
    /// `local_min = ceil( (P · rd · 240000) / (Q · rn) )` is computed with FAIL-CLOSED arithmetic: every
    /// multiply/add is overflow-checked and the final tick must fit `Int64` exactly. No `&*`/`&+`, no
    /// `clamping:`, no truncation — any non-fitting intermediate or result throws `audioTimeMathOverflow`.
    func firstProjectTick(sourceAtLeast target: RationalSourceTime, notBefore: Int64) throws -> Int64 {
        let anchor = mapping.trimRange.start
        let rn = mapping.rate.numerator               // > 0
        let rd = mapping.rate.denominator             // > 0
        let delta = try target.subtracting(anchor)    // P/Q, reduced
        if delta.numerator <= 0 {
            // Target at or below the anchor → reached at the base tick (clamped to `notBefore`).
            return max(baseProjectTick, notBefore)
        }
        let p = UInt64(delta.numerator)               // P > 0
        let q = UInt64(delta.denominator)             // Q > 0
        // factor = rd · 240000  (checked UInt64). denom = Q · rn (checked UInt64).
        let factor = try checkedMulU64(UInt64(rd), UInt64(TickClock.ticksPerSecond))
        let denom = try checkedMulU64(q, UInt64(rn))
        // numerator = P · factor (exact 128-bit), local_min = ceil(numerator / denom), checked Int64 fit.
        let numerator = UInt128.multiplyU64(p, factor)
        let localMin = try AffineSourceMap.ceilDiv128by64(numerator, denom)   // exact Int64 magnitude
        let tick = try checkedAddI64(baseProjectTick, localMin)
        return max(tick, notBefore)
    }

    /// Exact `ceil(n / d)` for a 128-bit dividend and a positive 64-bit divisor, returning the result as
    /// an `Int64`. FAIL-CLOSED: the quotient must fit `Int64` (its high word must be zero and the low
    /// word `<= Int64.max`) and the `+1` ceil step must not overflow — otherwise `audioTimeMathOverflow`.
    static func ceilDiv128by64(_ n: UInt128, _ d: UInt64) throws -> Int64 {
        let (quotient, remainder) = n.divMod(byU64: d)
        // The quotient must fit a non-negative Int64 exactly (no truncation of the high word).
        guard quotient.high == 0, quotient.low <= UInt64(Int64.max) else {
            throw AudioEvaluationError.audioTimeMathOverflow
        }
        let q = Int64(quotient.low)
        if remainder == 0 { return q }
        let (ceil, overflow) = q.addingReportingOverflow(1)
        guard !overflow else { throw AudioEvaluationError.audioTimeMathOverflow }
        return ceil
    }

    /// Checked `UInt64 × UInt64`; throws on overflow (never wraps).
    private func checkedMulU64(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let (value, overflow) = a.multipliedReportingOverflow(by: b)
        guard !overflow else { throw AudioEvaluationError.audioTimeMathOverflow }
        return value
    }

    /// Checked `Int64 + Int64`; throws on overflow (never wraps).
    private func checkedAddI64(_ a: Int64, _ b: Int64) throws -> Int64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw AudioEvaluationError.audioTimeMathOverflow }
        return value
    }
}
