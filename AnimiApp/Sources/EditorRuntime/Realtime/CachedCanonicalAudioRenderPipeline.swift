import Foundation
import AnimiEngineCore

/// Slice-005 Stage 2 — the app-side `CanonicalAudioRenderPipeline` that routes an evaluated `AudioPlan`
/// through the deterministic `CanonicalPCMRenderCache` instead of decoding on the live Play path.
///
/// Flow (NO real media decode here — the decode is the injected `CanonicalPCMRenderer` behind the cache,
/// which Stage 2 leaves abstract):
///
///   CanonicalAudioRenderRequest
///     ─▶ deterministic non-empty planIdentity  (from AudioPlan content)
///     ─▶ CanonicalPCMRenderKey(revision, epoch, planIdentity, range)
///     ─▶ CanonicalPCMRenderCache.chunk(for:key:)   (coalesced, bounded, fail-closed)
///     ─▶ chunk.sources : [PreviewMixSource]
///
/// Fail-closed: a non-empty plan is NEVER turned into silence. Any renderer/cache error throws (it never
/// becomes `[]`). An empty plan is the ONLY legitimate `[]` — see `prepareInitialPreroll`.
struct CachedCanonicalAudioRenderPipeline: CanonicalAudioRenderPipeline, Sendable {

    let cache: CanonicalPCMRenderCache
    /// Deterministic plan→identity function. Default: `CanonicalAudioPlanIdentity.string(for:)`. Must return
    /// a non-empty string for a non-empty plan; an empty return propagates as `.invalidPCMRenderPlanIdentity`
    /// via `CanonicalPCMRenderKey`'s fail-closed init.
    let planIdentityProvider: @Sendable (AudioPlan) throws -> String

    init(
        cache: CanonicalPCMRenderCache,
        planIdentityProvider: @escaping @Sendable (AudioPlan) throws -> String = { plan in
            CanonicalAudioPlanIdentity.string(for: plan)
        }
    ) {
        self.cache = cache
        self.planIdentityProvider = planIdentityProvider
    }

    func prepareInitialPreroll(
        _ request: CanonicalAudioRenderRequest,
        onDiagnostic: (@MainActor (_ event: String, _ detail: String) -> Void)?
    ) async throws -> [PreviewMixSource] {
        // EMPTY PLAN (chosen behavior): return [] directly without touching the cache or the renderer. An
        // empty plan is legitimate silence; there is no chunk worth rendering or caching. This avoids useless
        // renderer work and keeps a genuinely-empty epoch cheap. (The cache itself would also accept an empty
        // chunk, but the pipeline never produces one here.)
        if request.plan.segments.isEmpty {
            return []
        }

        // Deterministic identity from plan content; empty → fail-closed via the key's init.
        let planIdentity = try planIdentityProvider(request.plan)
        let key = try CanonicalPCMRenderKey(
            revision: request.revision,
            epoch: request.epoch,
            planIdentity: planIdentity,
            range: request.range)

        await onDiagnostic?(
            "preview.audio.canonical.render.begin",
            "segments=\(request.plan.segments.count) range=\(request.range.start)..<\(request.range.end)")

        // Cache renders (coalesced) on a miss, validates chunk.key == key, and never caches failures. A
        // non-empty plan that fails here THROWS — it must not become silence.
        let chunk = try await cache.chunk(for: request, key: key)

        await onDiagnostic?(
            "preview.audio.canonical.render.end",
            "sources=\(chunk.sources.count)")

        return chunk.sources
    }
}

/// Slice-005 Stage 2 — the deterministic `AudioPlan` → identity string used as the PCM cache `planIdentity`.
///
/// Determinism contract: the identity depends ONLY on the canonical content fields the renderer needs to be
/// correct — never on `Date`, `UUID`, randomness, a file URL, or object identity, and never on Swift's
/// process-randomized `hashValue`. Same plan → identical identity; any meaningful content change → different.
///
/// COLLISION SAFETY (Stage-2 P0 fix): canonical identifiers (`AudioClipID`/`AudioSourceID`/… `.raw`) only
/// reject EMPTY strings — they may legally contain ANY other character, including the `\t`/`\n`/`:` we use as
/// markup. A delimiter-join would let `clip="a\tsource=b"` forge the boundary of the next field and collide
/// with a different plan. So every VARIABLE-LENGTH string field is **length-prefixed by its UTF-8 byte
/// count**: `s:<byteCount>:<raw>`. A reader frames the value by counting exactly `<byteCount>` bytes, so no
/// embedded separator can be misread — the encoding is injective over distinct field tuples. Fixed-format
/// tokens (`i:<int>`, `b:<0|1>`, `role:<rawValue>` (closed enum, no separators), `layout:<kind>:<count>`)
/// carry no untrusted variable content, so they concatenate safely.
enum CanonicalAudioPlanIdentity {

    /// Build the deterministic identity for `plan`. Pure value function; no I/O.
    static func string(for plan: AudioPlan) -> String {
        var out = ""
        // Plan-level requested interval (typed integer tokens).
        out += "interval"
        out += int(plan.sampleInterval.start)
        out += int(plan.sampleInterval.end)
        // Ordered segment count, then each segment IN ORDER (segment order is meaningful → not sorted).
        out += "segcount"
        out += int(Int64(plan.segments.count))
        for (i, seg) in plan.segments.enumerated() {
            out += appendSegment(index: i, seg)
        }
        return out
    }

    private static func appendSegment(index: Int, _ seg: AudioSegmentPlan) -> String {
        var s = "seg"
        s += int(Int64(index))
        // Variable-length string IDs: length-prefixed (collision-free).
        s += "clip"; s += str(seg.clipID.raw)
        s += "source"; s += str(seg.sourceID.raw)
        s += "track"; s += str(seg.trackID.raw)
        // role is a closed `String`-backed enum (videoLayer/music/voiceover/soundEffect) — no separators, but
        // length-prefix it too for uniformity / future-proofing.
        s += "role"; s += str(seg.role.rawValue)
        s += "dest"; s += int(seg.destinationSamples.start); s += int(seg.destinationSamples.end)
        s += "srcStart"; s += rational(seg.sourceStart)
        s += "srcEnd"; s += rational(seg.sourceEnd)
        s += "trimStart"; s += rational(seg.effectiveTrim.start)
        s += "trimEnd"; s += rational(seg.effectiveTrim.end)
        s += "muted"; s += bool(seg.isMuted)
        s += "gain"; s += int(seg.gain.raw)
        s += "rate"; s += int(seg.sourceSampleRate)
        s += "layout"; s += channelLayout(seg.channelLayout)
        s += "stream"; s += str(seg.streamIdentity.raw)
        // sceneID is optional: tag presence explicitly so `nil` can never equal an empty-string id (IDs can't
        // be empty, but the tag keeps the optional unambiguous).
        if let scene = seg.sceneID {
            s += "scene1"; s += str(scene.raw)
        } else {
            s += "scene0"
        }
        return s
    }

    /// Length-prefixed, collision-free encoding of a variable-length string: `s:<utf8ByteCount>:<raw>`.
    private static func str(_ value: String) -> String {
        "s:\(value.utf8.count):\(value)"
    }

    /// Typed integer token: `i:<value>`. (Decimal `Int64`, fixed character set — safe to concatenate.)
    private static func int(_ value: Int64) -> String { "i:\(value)" }

    /// Typed bool token: `b:0` / `b:1`.
    private static func bool(_ value: Bool) -> String { "b:\(value ? 1 : 0)" }

    /// Reduced rational as two typed integer tokens (denominator is positive + reduced by the type).
    private static func rational(_ t: RationalSourceTime) -> String {
        "r" + int(t.numerator) + int(t.denominator)
    }

    /// Layout: `layout:<kind>:<count>` — `kind` is a closed enum (no untrusted variable content).
    private static func channelLayout(_ layout: AudioChannelLayoutDescriptor) -> String {
        let kind: String
        switch layout.kind {
        case .mono: kind = "mono"
        case .stereo: kind = "stereo"
        case .discrete: kind = "discrete"
        }
        return "layout:\(kind)" + int(Int64(layout.channelCount))
    }
}
