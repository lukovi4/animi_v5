import Foundation

/// Slice-005 Stage A — typed, fail-closed errors for the app→canonical realtime-audio bridges.
///
/// Stage A builds canonical *inputs* (a populated `AudioManifest`, a list of
/// `ResolvedAudioSourceDescriptor`, an `AudioSessionAdapter`, and the event mapping) from the existing
/// app audio model. Every bridge rejects invalid/ambiguous input with a typed case instead of clamping,
/// skipping silently, or fabricating a value — the canonical model must never carry an invalid fact.
///
/// This is an **app-side** type. It is NOT part of `AnimiEngineCore` and imports no engine internals
/// beyond the public canonical types it bridges to.
enum AppRealtimeAudioIntegrationError: Error, Equatable {

    // MARK: - AudioManifest bridge (§3.1a)

    /// An app `AudioPayload` carried no `assetRef`, so no canonical source can be referenced.
    case missingAssetReference(itemIndex: Int)
    /// `item.startUs`/`durationUs` could not be mapped exactly onto the 240 kHz project tick grid, or
    /// produced a non-positive / inverted destination interval.
    case invalidDestination(itemIndex: Int, startUs: Int64, durationUs: Int64)
    /// `trimStartUs`/`trimEndUs` produced an inverted/empty or otherwise invalid source-trim range.
    case invalidSourceTrim(itemIndex: Int, trimStartUs: Int64, trimEndUs: Int64)
    /// The app `volume` was out of `0.0...1.0` or non-finite — `AudioGain` must not carry an invalid
    /// value, and the bridge never clamps.
    case invalidGain(itemIndex: Int, volume: Double)
    /// Two clips derived the same canonical clip identity — an ambiguous manifest (fail closed rather
    /// than silently overwrite).
    case duplicateClipIdentity(raw: String)
    /// Constructing a canonical identifier (`AudioSourceID`/`AudioTrackID`/`AudioClipID`/
    /// `GlobalAudioAssetID`/`AudioStreamIdentity`) failed (e.g. an empty derived id).
    case identifierConstructionFailed(detail: String)
    /// Video-layer original audio is **not** mappable on Stage A (no canonical
    /// `MediaReference`/`SceneLayerReference` resolution is wired yet). Stage A refuses rather than
    /// fabricate a mapping; `includeOriginalFromVideoSlots` must be `false` until Stage B/C.
    case videoLayerOriginalAudioUnsupportedInStageA

    // MARK: - Source-descriptor resolver (§3.1b)

    /// No descriptor was produced for a source referenced by a clip.
    case missingSourceDescriptor(sourceRaw: String)
    /// More than one descriptor resolved for the same source — ambiguous, fail closed.
    case duplicateSourceDescriptor(sourceRaw: String)

    // MARK: - Session adapter (§3.2)

    /// `queryActualOutput()` was called before `activate()`.
    case queryBeforeActivation
    /// The probed/queried output sample rate was non-positive or non-integral.
    case invalidOutputSampleRate(raw: Double)
    /// The probed/queried route identifier was empty.
    case emptyOutputRoute
    /// The probed channel count was non-positive.
    case invalidChannelCount(Int)

    // MARK: - Event mapping (§3.6)

    /// The app `AudioSessionEvent` has no exact canonical realtime mapping.
    case unmappableSessionEvent(detail: String)

    // MARK: - Stage C lifecycle (controller)

    /// A non-empty canonical `AudioPlan` exists, but the background/prewarmed PCM renderer/cache that turns
    /// it into `PreviewMixSource` samples is not available. The controller fails closed rather than schedule
    /// silence for audible content — there is NO silent fallback for non-empty audio.
    case audioRenderPipelineUnavailable(reason: String)
    /// The requested playhead (`fromSeconds`) could not be converted to a canonical anchor (negative,
    /// non-finite, or it overflowed the checked tick/sample arithmetic).
    case invalidPlayheadAnchor(fromSeconds: Double)
    /// Checked arithmetic overflowed while computing a bounded preroll range / snapshot coverage.
    case anchorArithmeticOverflow(detail: String)

    // MARK: - Runtime plan / media resolution

    /// The source media file is missing / not found at its resolved URL.
    case mediaUnavailable(sourceRaw: String)
    /// The source media is corrupt or unreadable.
    case mediaCorrupt(sourceRaw: String, detail: String)
    /// The source media is an unsupported shape.
    case mediaUnsupported(sourceRaw: String, detail: String)
    /// An app `AudioAssetRef` could not be resolved to a playable URL (e.g. a `.bundled` SFX, whose
    /// resolution path is not wired for the canonical preview — fail-closed, never silent).
    case audioAssetUnresolvable(detail: String)
    /// The runtime had no current editor state / timeline to evaluate.
    case runtimeStateUnavailable
    /// The exact canonical source start for an interior bounded range could not be represented (the
    /// rational advance overflowed). Fail closed rather than approximate.
    case sourceStartNotRepresentable(detail: String)

    // MARK: - Stage 1 PCM render cache (§ canonical-audio-preview-export-implementation-plan)

    /// A `CanonicalPCMRenderKey` was constructed with an empty `planIdentity` — the deterministic cache key
    /// must carry a non-empty plan identity (no `Date`/`UUID`/URL/object identity), fail closed.
    case invalidPCMRenderPlanIdentity
    /// A `CanonicalPCMRenderCache` was constructed with a non-positive capacity — capacity must be `> 0`.
    case invalidPCMRenderCacheCapacity(Int)
    /// A `CanonicalPCMRenderer` failed to produce a chunk (or a chunk's sources violated the exact-range
    /// invariant). Carried so failures fail visibly and are NEVER cached as success.
    case pcmRenderFailed(reason: String)
}
