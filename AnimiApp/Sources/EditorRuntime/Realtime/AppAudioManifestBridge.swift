import Foundation
import AnimiEngineCore

/// Slice-005 Stage A — builds a populated canonical `AudioManifest` from the app audio model
/// (plan §3.1a). This is the corrected critical bridge: the app's `CanonicalProjectManifest` is built
/// for video only (`manifest.audio == .empty`), so without this bridge the canonical `AudioEvaluator`
/// sees zero clips and produces silence.
///
/// Stage A scope: produce the manifest *value* only. It does NOT build the evaluation window, run the
/// evaluator, decode audio, or wire any playback lifecycle (Stage B/C). Pure, deterministic, fail-closed.
///
/// Mapping (per item):
/// - `destination` = `ProjectTimeRange` from `[startUs, endUs)` via a **deterministic outward
///   projection** onto the 240 kHz tick grid: `startTick = floor(startUs·240000/1e6)`,
///   `endTick = ceil(endUs·240000/1e6)`. App `TimeUs` is an arbitrary `Int64` (import/trim paths derive
///   it through `Double`), so no exact 25 µs alignment can be assumed; the interval is covered outward
///   rather than rejected. Error is bounded **< 1 canonical tick per boundary** (≈ 4.17 µs). Integer-only.
/// - `sourceTrim`  = `RationalSourceRange` from `trimStartUs ..< trimEndUs` (exact rational seconds —
///   unchanged; the audible source window stays exact).
/// - `gain`        = `AudioGain` from `volume`, fail-closed (`0...1` finite → `0...1_000_000`, else throw).
/// - `playbackPolicy` = `.once` (the only v1 case — no loop / `loopToFit`).
/// - global audio  → `AudioAssetReference.globalAudio(GlobalAudioAssetID)`; role mapped 1:1.
///
/// Determinism: tracks ordered by role; sources by derived id; clips by `(trackID, destination.start,
/// clipID)`. Duplicate derived clip identities are a typed failure (no silent overwrite).
enum AppAudioManifestBridge {

    /// One app audio item to bridge: its stable timeline position and its payload. A small pure value so
    /// tests need no full `CanonicalTimeline` construction; the call site fills it from
    /// `CanonicalTimeline.TimelineItem` (`startUs`/`durationUs`) + `AudioPayload`.
    struct Input: Equatable {
        /// Stable index of this item within the timeline's audio items (used for diagnostics + id derivation).
        let index: Int
        /// `TimelineItem.startUs` resolved to an absolute project start (µs). Non-negative.
        let startUs: Int64
        /// `TimelineItem.durationUs` (µs). Must be > 0.
        let durationUs: Int64
        /// The app audio payload.
        let payload: AudioPayload

        init(index: Int, startUs: Int64, durationUs: Int64, payload: AudioPayload) {
            self.index = index
            self.startUs = startUs
            self.durationUs = durationUs
            self.payload = payload
        }
    }

    /// Microseconds per second — the exact denominator for `sourceTrim` rational seconds (`us / 1e6`).
    /// (The canonical project tick rate is `TickClock.n` = 240 000/s, applied as the reduced 6/25
    /// factor in the destination projection below.)
    private static let microsPerSecond: Int64 = 1_000_000

    /// Build a populated `AudioManifest` from the app audio items.
    ///
    /// - Parameters:
    ///   - items: the app audio items (each = a timeline position + `AudioPayload`).
    ///   - includeOriginalFromVideoSlots: if `true`, video-layer original audio would be included — but
    ///     Stage A cannot map it correctly, so this throws `videoLayerOriginalAudioUnsupportedInStageA`
    ///     (no fake mapping). Must be `false` on Stage A.
    /// - Parameter projectEndUs: when non-nil, each clip destination is CLAMPED to `[startUs, min(end,
    ///   projectEndUs))`. The canonical `ProjectValidator` rejects a clip whose `destination.end >
    ///   projectEnd` (`audioDestinationOutsideProject`); an imported track longer than the project would
    ///   otherwise fail canonical and force a fallback. Clamping mirrors how the legacy path tolerates an
    ///   over-length music track (it just plays up to the project end). `nil` = no clamp (legacy callers).
    /// - Returns: `AudioManifest.empty` when `items` is empty; otherwise a populated, deterministic manifest.
    static func buildManifest(
        items: [Input],
        includeOriginalFromVideoSlots: Bool,
        projectEndUs: Int64? = nil
    ) throws -> AudioManifest {
        if includeOriginalFromVideoSlots {
            // Stage A refuses rather than fabricate a video-layer mapping (plan §3.1a, blocker for Stage B/C).
            throw AppRealtimeAudioIntegrationError.videoLayerOriginalAudioUnsupportedInStageA
        }
        guard !items.isEmpty else { return .empty }

        // One canonical track per app role (deterministic order: music, voiceover, soundEffect).
        var roleToTrackID: [AudioSourceRole: AudioTrackID] = [:]
        var sourceByID: [AudioSourceID: AudioSourceEntry] = [:]
        var clips: [AudioClipEntry] = []
        var seenClipRaw: Set<String> = []

        for item in items {
            guard let assetRef = item.payload.assetRef else {
                throw AppRealtimeAudioIntegrationError.missingAssetReference(itemIndex: item.index)
            }

            let role = canonicalRole(item.payload.role)
            let trackID = try roleToTrackID[role] ?? makeTrackID(for: role)
            roleToTrackID[role] = trackID

            // Source identity is derived from the stable asset reference; equal assets share one source.
            let sourceID = try makeSourceID(for: assetRef)
            let globalAssetID = try makeGlobalAudioAssetID(for: assetRef)
            let entry = AudioSourceEntry(id: sourceID, asset: .globalAudio(globalAssetID))
            if let existing = sourceByID[sourceID], existing != entry {
                // Same derived id, different asset — ambiguous source identity.
                throw AppRealtimeAudioIntegrationError.identifierConstructionFailed(
                    detail: "source id collision for \(sourceID.raw)")
            }
            sourceByID[sourceID] = entry

            // Clamp the clip's [startUs, endUs) to the project end (if known) so an over-length imported
            // track does not push `destination.end` past `projectEnd` (→ canonical `audioDestinationOutsideProject`).
            let clampedDurationUs: Int64
            if let projectEndUs, item.startUs < projectEndUs {
                clampedDurationUs = min(item.durationUs, projectEndUs - item.startUs)
            } else if let projectEndUs, item.startUs >= projectEndUs {
                // Item starts at/after the project end — nothing audible; skip it (not an error).
                continue
            } else {
                clampedDurationUs = item.durationUs
            }
            let destination = try makeDestination(
                startUs: item.startUs, durationUs: clampedDurationUs, itemIndex: item.index)
            let sourceTrim = try makeSourceTrim(
                trimStartUs: item.payload.trimStartUs, trimEndUs: item.payload.trimEndUs, itemIndex: item.index)
            let gain = try makeGain(volume: item.payload.volume, itemIndex: item.index)

            let clipID = try makeClipID(itemIndex: item.index, sourceID: sourceID)
            guard seenClipRaw.insert(clipID.raw).inserted else {
                throw AppRealtimeAudioIntegrationError.duplicateClipIdentity(raw: clipID.raw)
            }

            clips.append(AudioClipEntry(
                id: clipID,
                trackID: trackID,
                sourceID: sourceID,
                videoLayer: nil,                       // global audio only on Stage A
                destination: destination,
                sourceTrim: sourceTrim,
                gain: gain,
                isMuted: false,                        // app model has no per-clip mute on Stage A; not loopable either
                playbackPolicy: .once))                // no loop / loopToFit
        }

        // Deterministic tables.
        let tracks = roleToTrackID
            .sorted { roleOrder($0.key) < roleOrder($1.key) }
            .map { AudioTrackEntry(id: $0.value, role: $0.key) }
        let sources = sourceByID.values.sorted { $0.id < $1.id }
        clips.sort {
            if $0.trackID != $1.trackID { return $0.trackID < $1.trackID }
            if $0.destination.start != $1.destination.start { return $0.destination.start < $1.destination.start }
            return $0.id < $1.id
        }

        return AudioManifest(sources: sources, tracks: tracks, clips: clips)
    }

    // MARK: - Role mapping

    private static func canonicalRole(_ role: AudioRole) -> AudioSourceRole {
        switch role {
        case .music: return .music
        case .voiceover: return .voiceover
        case .sfx: return .soundEffect
        }
    }

    /// Deterministic role ordering for track/clip sorting (`videoLayer` reserved for Stage B/C).
    private static func roleOrder(_ role: AudioSourceRole) -> Int {
        switch role {
        case .music: return 0
        case .voiceover: return 1
        case .soundEffect: return 2
        case .videoLayer: return 3
        }
    }

    // MARK: - Identity derivation

    private static func makeTrackID(for role: AudioSourceRole) throws -> AudioTrackID {
        do { return try AudioTrackID("app.audio.track.\(role.rawValue)") }
        catch { throw AppRealtimeAudioIntegrationError.identifierConstructionFailed(detail: "track:\(role.rawValue)") }
    }

    /// A stable string for an asset reference, identical for equal references (so equal assets share a source).
    private static func assetKey(_ ref: AudioAssetRef) -> String {
        switch ref {
        case .bundled(let id): return "bundled:\(id)"
        case .imported(let assetId, _): return "imported:\(assetId.rawValue.uuidString)"
        }
    }

    private static func makeSourceID(for ref: AudioAssetRef) throws -> AudioSourceID {
        do { return try AudioSourceID("app.audio.source.\(assetKey(ref))") }
        catch { throw AppRealtimeAudioIntegrationError.identifierConstructionFailed(detail: "source:\(assetKey(ref))") }
    }

    private static func makeGlobalAudioAssetID(for ref: AudioAssetRef) throws -> GlobalAudioAssetID {
        do { return try GlobalAudioAssetID("app.audio.asset.\(assetKey(ref))") }
        catch { throw AppRealtimeAudioIntegrationError.identifierConstructionFailed(detail: "asset:\(assetKey(ref))") }
    }

    private static func makeClipID(itemIndex: Int, sourceID: AudioSourceID) throws -> AudioClipID {
        do { return try AudioClipID("app.audio.clip.\(itemIndex).\(sourceID.raw)") }
        catch { throw AppRealtimeAudioIntegrationError.identifierConstructionFailed(detail: "clip:\(itemIndex)") }
    }

    // MARK: - Time mapping (µs → canonical, outward / fail-closed)

    /// Map the app half-open microsecond interval `[startUs, endUs)` onto a canonical half-open tick
    /// interval by the SHARED outward projection policy (`Slice005TickProjection`: floor start, ceil end).
    /// App `TimeUs` is not guaranteed to land on the 240 kHz grid, so the interval is covered outward
    /// (never rejected for non-alignment, never silently clamped). Fail-closed on negative start,
    /// non-positive duration, overflow, or a degenerate final range. No `Float`/`Double`.
    private static func makeDestination(
        startUs: Int64, durationUs: Int64, itemIndex: Int
    ) throws -> ProjectTimeRange {
        guard startUs >= 0, durationUs > 0 else {
            throw AppRealtimeAudioIntegrationError.invalidDestination(
                itemIndex: itemIndex, startUs: startUs, durationUs: durationUs)
        }
        let endUs = startUs.addingReportingOverflow(durationUs)
        guard !endUs.overflow,
              let startTicks = Slice005TickProjection.floorTicks(startUs),
              let endTicks = Slice005TickProjection.ceilTicks(endUs.partialValue),
              let start = try? ProjectTime(ticks: startTicks),
              let end = try? ProjectTime(ticks: endTicks),
              let range = try? ProjectTimeRange(start: start, end: end)   // requires end > start
        else {
            throw AppRealtimeAudioIntegrationError.invalidDestination(
                itemIndex: itemIndex, startUs: startUs, durationUs: durationUs)
        }
        return range
    }

    private static func makeSourceTrim(
        trimStartUs: Int64, trimEndUs: Int64, itemIndex: Int
    ) throws -> RationalSourceRange {
        // Exact rational seconds: us / 1_000_000 (auto-reduced by RationalSourceTime).
        guard trimStartUs >= 0, trimEndUs > trimStartUs,
              let start = try? RationalSourceTime(numerator: trimStartUs, denominator: microsPerSecond),
              let end = try? RationalSourceTime(numerator: trimEndUs, denominator: microsPerSecond),
              let range = try? RationalSourceRange(start: start, end: end)
        else {
            throw AppRealtimeAudioIntegrationError.invalidSourceTrim(
                itemIndex: itemIndex, trimStartUs: trimStartUs, trimEndUs: trimEndUs)
        }
        return range
    }

    /// Map app `volume` to canonical `AudioGain`, fail-closed.
    /// Finite `0.0...1.0` → exact `0...1_000_000`; out-of-range or non-finite → typed failure. No clamp.
    private static func makeGain(volume: Float, itemIndex: Int) throws -> AudioGain {
        let v = Double(volume)
        guard v.isFinite, v >= 0.0, v <= 1.0 else {
            throw AppRealtimeAudioIntegrationError.invalidGain(itemIndex: itemIndex, volume: v)
        }
        let raw = Int64((v * Double(AudioGain.unityRaw)).rounded())
        guard let gain = try? AudioGain(raw: raw) else {
            throw AppRealtimeAudioIntegrationError.invalidGain(itemIndex: itemIndex, volume: v)
        }
        return gain
    }
}
