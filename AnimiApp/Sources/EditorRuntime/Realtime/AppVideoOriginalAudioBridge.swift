import Foundation
import AnimiEngineCore

/// Slice-005 Stage 0+1 — builds the canonical **video-original** audio representation for a user video
/// block, WITHOUT touching the visual Next bridge (which still renders user video through `.image` +
/// dynamic texture). The audio path needs a real `SceneLayerContent.video(VideoBinding)` payload layer
/// so `AudioEvaluationWindowBuilder.resolveBinding` can copy the layer's `sourceMapping`; this bridge is
/// the AUDIO-ONLY mirror of that layer (owner decision: defer the visual `.video` cutover).
///
/// PARITY CONTRACT (the reason this is correct, not a fabrication):
/// The visual user-video timing is `NextVideoTimeMapping.targetVideoTime(sceneSeconds, winStart, winEnd)`
/// `= clamp(winStart + max(0, sceneSeconds), winStart, winEnd − 1/600)`. The canonical
/// `SourceTimeMapping.target(sceneTime) = trimStart + rate·(sceneTicks/240000)`. With `trimStart = winStart`
/// and `rate = 1/1` the two are identical in the interior; the `winEnd − 1/600` epsilon is the resolver's
/// read-side upper clamp (hold-last), not part of the source mapping. The half-open `trimRange`
/// `[winStart, winEnd)` mirrors the window. `AppVideoOriginalAudioBridgeParityTests` pins this against the
/// visual `NextVideoTimeMapping` for blockStart = 0 / > 0 / trim in-out / hold-last epsilon.
enum AppVideoOriginalAudioBridge {

    private static let microsPerSecond: Int64 = 1_000_000
    /// The canonical native timescale used for a user-video audio source. The source mapping is exact
    /// rational (never rounded onto this), so any positive value is contract-valid; 600 mirrors the
    /// resolver's `CMTime` timescale (`NextVideoBlockResolver.timescale`).
    private static let nativeTimescaleUnits: Int64 = 600

    /// One user video block resolved from app state, expressed as primitives (no TVECore dependency).
    struct Input: Equatable {
        /// The app block id (becomes the canonical `LayerID` — same convention as
        /// `CompiledTemplateConverter`'s `LayerID(block.blockID)`).
        let blockID: String
        /// The canonical scene instance id this block's scene maps to (must equal the scene payload's id).
        let sceneInstanceIDRaw: String
        /// The media reference for the AUDIO-only `.video` layer. It must be internally consistent between
        /// the clip's `.videoLayerMedia(media)` and the payload layer's `VideoBinding.media` (the evaluator
        /// asserts THOSE two are equal). It is an AUDIO-INTERNAL namespace — it is NOT claimed to equal the
        /// visual layer's media reference (which is `cp4-<blockID>` single-scene / `cp5-s<i>-<blockID>`
        /// multi-scene). The audio evaluator never cross-references the visual document, so internal
        /// consistency is sufficient and correct.
        let mediaReferenceRaw: String
        /// Trim window start, seconds (== `VideoSelection.winStart` == `PersistedVideoSelection.trimStart`).
        let winStart: Double
        /// Trim window end, seconds (== `VideoSelection.winEnd` == `PersistedVideoSelection.trimEnd`).
        let winEnd: Double
        /// Video original-audio volume `0...1` (app `PersistedVideoSelection.volume`).
        let volume: Float
        /// Whether the video's original audio is muted (`PersistedVideoSelection.isMuted`).
        let isMuted: Bool
        /// Project-time span of this block's SCENE, microseconds `[sceneStartUs, sceneStartUs+sceneDurationUs)`.
        let sceneStartUs: Int64
        let sceneDurationUs: Int64
        /// The block's ACTIVE interval WITHIN the scene, microseconds `[blockStartUs, blockEndUs)` relative
        /// to the scene start. THIS STAGE SUPPORTS ONLY A SCENE-FILLING BLOCK: `blockStartUs == 0` and
        /// `blockEndUs == sceneDurationUs`; any other value is FAIL-CLOSED (typed `mediaUnsupported`). Reason:
        /// the canonical `AudioEvaluator` video-layer clock is scene-local (`sceneMediaTime = T − sceneStart`),
        /// so a non-zero block offset would make `sourceStart = winStart + offset` (wrong). Authored partial
        /// block timing is a documented remaining follow-up.
        let blockStartUsInScene: Int64
        let blockEndUsInScene: Int64
    }

    /// The canonical pieces one video block contributes to the audio window: a scene-payload `.video`
    /// layer (for binding resolution), the source/track/clip manifest entries, and the source descriptor.
    struct Built {
        let layer: SceneLayer
        let sceneInstanceID: SceneInstanceID
        let source: AudioSourceEntry
        let track: AudioTrackEntry
        let clip: AudioClipEntry
        let descriptor: ResolvedAudioSourceDescriptor
        /// The derived source id raw, so the caller can map it to the resolved file URL for render.
        let sourceRaw: String
    }

    /// Build the canonical video-original audio pieces for one block. Fail-closed (typed) on any invalid
    /// timing/trim/gain — NEVER a silent drop, NEVER a fabricated mapping.
    static func build(_ input: Input) throws -> Built {
        // Window must be a valid half-open seconds interval → µs for the canonical rational trim.
        guard input.winStart.isFinite, input.winEnd.isFinite, input.winEnd > input.winStart,
              input.winStart >= 0 else {
            throw AppRealtimeAudioIntegrationError.invalidSourceTrim(
                itemIndex: 0,
                trimStartUs: Int64((input.winStart * 1_000_000).rounded()),
                trimEndUs: Int64((input.winEnd * 1_000_000).rounded()))
        }
        let trimStartUs = Int64((input.winStart * Double(microsPerSecond)).rounded())
        let trimEndUs = Int64((input.winEnd * Double(microsPerSecond)).rounded())

        let sceneID = try SceneInstanceID(input.sceneInstanceIDRaw)
        let layerID = try LayerID(input.blockID)
        let media = try MediaReference(input.mediaReferenceRaw)

        // sourceTrim = [winStart, winEnd) exact rational seconds (mirrors AppAudioManifestBridge.makeSourceTrim).
        guard trimStartUs >= 0, trimEndUs > trimStartUs,
              let trimStart = try? RationalSourceTime(numerator: trimStartUs, denominator: microsPerSecond),
              let trimEnd = try? RationalSourceTime(numerator: trimEndUs, denominator: microsPerSecond),
              let trimRange = try? RationalSourceRange(start: trimStart, end: trimEnd) else {
            throw AppRealtimeAudioIntegrationError.invalidSourceTrim(
                itemIndex: 0, trimStartUs: trimStartUs, trimEndUs: trimEndUs)
        }

        // SourceTimeMapping: trimStart = winStart, rate 1/1 — provably equal to the visual NextVideoTimeMapping
        // interior (target = winStart + sceneSeconds). Pinned by AppVideoOriginalAudioBridgeParityTests.
        let timescale = try SourceTimescale(unitsPerSecond: nativeTimescaleUnits)
        let mapping = SourceTimeMapping(trimRange: trimRange, nativeTimescale: timescale, rate: .oneToOne)
        let binding = VideoBinding(media: media, sourceMapping: mapping)

        // FAIL-CLOSED on non-zero block timing (P1). The canonical `AudioEvaluator` video-layer clock is
        // SCENE-LOCAL: `sceneMediaTime = T − sceneStart`, so a clip whose `destination.start` lies AFTER the
        // scene start (block does not fill the scene) yields `sourceStart = winStart + (destination.start −
        // sceneStart)` — the source is advanced by the block offset, which is WRONG (a user video must begin
        // at `winStart` when its block first appears). Authored partial block timing is therefore a documented
        // REMAINING FOLLOW-UP, not implemented in this stage. Only a SCENE-FILLING block is supported:
        // `[0, sceneDuration)`. Anything else fails typed (never a silently mis-timed segment).
        guard input.blockStartUsInScene == 0, input.blockEndUsInScene == input.sceneDurationUs,
              input.sceneDurationUs > 0 else {
            throw AppRealtimeAudioIntegrationError.mediaUnsupported(
                sourceRaw: input.blockID,
                detail: "non-scene-filling video block timing not supported (blockStart=\(input.blockStartUsInScene), blockEnd=\(input.blockEndUsInScene), sceneDuration=\(input.sceneDurationUs)); AudioEvaluator's scene-local clock would mis-time sourceStart")
        }
        // The audio-only scene-payload layer; its activeRange is the (scene-filling) block interval.
        let layer = try makeAudioOnlyVideoLayer(
            layerID: layerID, binding: binding,
            blockStartUsInScene: input.blockStartUsInScene, blockEndUsInScene: input.blockEndUsInScene)

        // Manifest entries — IDs are namespaced by SCENE INSTANCE + block (P0). The same `blockID` can appear
        // in multiple scenes; namespacing by `sceneInstanceIDRaw` keeps source/track/clip ids globally unique
        // so two scenes never collide / overwrite `resolvedSourcesByID`.
        let scope = "\(input.sceneInstanceIDRaw):\(input.blockID)"
        let sourceRaw = "app.audio.source.videoLayer:\(scope)"
        let sourceID = try AudioSourceID(sourceRaw)
        let source = AudioSourceEntry(id: sourceID, asset: .videoLayerMedia(media))
        let trackID = try AudioTrackID("app.audio.track.videoLayer.\(scope)")
        let track = AudioTrackEntry(id: trackID, role: .videoLayer)

        // Destination = the block's project-time active interval (scene-filling: the whole scene span).
        let destStartUs = input.sceneStartUs + input.blockStartUsInScene
        let destDurationUs = input.blockEndUsInScene - input.blockStartUsInScene
        let destination = try makeDestination(startUs: destStartUs, durationUs: destDurationUs)
        let gain = try makeGain(volume: input.volume)
        let clip = AudioClipEntry(
            id: try AudioClipID("app.audio.clip.videoLayer.\(scope)"),
            trackID: trackID,
            sourceID: sourceID,
            videoLayer: SceneLayerReference(sceneID: sceneID, layerID: layerID),
            destination: destination,
            sourceTrim: trimRange,
            gain: gain,
            isMuted: input.isMuted,
            playbackPolicy: .once)

        // Descriptor source duration: the descriptor's `sourceDuration` describes the SOURCE material, not
        // the trimmed slice. We do NOT have a synchronous exact source duration on the app side
        // (`PersistedVideoSelection` carries only trim/volume/mute; AVAsset duration is async). The trim
        // window's END (`winEnd`) is an EXACT LOWER BOUND on the source duration — a half-open trim
        // `[winStart, winEnd)` cannot exceed the source, so `sourceDuration >= winEnd`. Using `winEnd` (not
        // the trim *length* `winEnd − winStart`) is the defensible exact lower bound: the source is at least
        // `winEnd` long. The evaluator bounds the audible slice to `sourceTrim ⊆ [0, sourceDuration)`, and
        // `winEnd == trimRange.end` so the slice fits exactly. Pinned by the descriptor-duration test.
        let sourceDurationUs = trimEndUs   // exact lower bound on the real source duration (≥ winEnd)
        let descriptor = ResolvedAudioSourceDescriptor(
            sourceID: sourceID,
            streamIdentity: try AudioStreamIdentity("stream:\(sourceRaw)"),
            sourceDuration: try RationalSourceTime(numerator: max(1, sourceDurationUs), denominator: microsPerSecond),
            sampleRate: 48_000,
            channelLayout: .mono)

        return Built(
            layer: layer, sceneInstanceID: sceneID, source: source, track: track, clip: clip,
            descriptor: descriptor, sourceRaw: sourceRaw)
    }

    // MARK: - Helpers

    /// A minimal-valid `.video` scene layer for AUDIO binding resolution only. The evaluator's audio
    /// builder reads `id` + `content` (the `VideoBinding.sourceMapping`); `placement`/`activeRange`/
    /// `zIndex`/`mediaPlacement` are required-non-nil construction inputs but are NOT consulted for audio.
    private static func makeAudioOnlyVideoLayer(
        layerID: LayerID, binding: VideoBinding, blockStartUsInScene: Int64, blockEndUsInScene: Int64
    ) throws -> SceneLayer {
        // activeRange mirrors the block's active interval within the scene (floor start, ceil end; ≥ 1 tick).
        let startTicks = Slice005TickProjection.floorTicks(max(0, blockStartUsInScene)) ?? 0
        let endTicks = max(startTicks + 1, Slice005TickProjection.ceilTicks(max(1, blockEndUsInScene)) ?? (startTicks + 1))
        let activeRange = try ScenePlaybackRange(
            start: try ScenePlaybackTime(ticks: startTicks),
            end: try ScenePlaybackTime(ticks: endTicks))
        // A unit placement frame — geometry is irrelevant to audio; this is the smallest valid rect.
        let frame = try FixedRect(
            x: try CanvasScalar(points: 0), y: try CanvasScalar(points: 0),
            width: try CanvasScalar(points: 1), height: try CanvasScalar(points: 1))
        let placement = try Placement(frame: frame, scale: .one, rotation: .zero)
        return SceneLayer(
            id: layerID, zIndex: 0, stableOrdinal: 0,
            activeRange: activeRange, placement: placement,
            mediaPlacement: .identity(fitMode: .contain),
            content: .video(binding), animation: nil)
    }

    /// Project-time destination `[startUs, endUs)` via the SHARED outward projection (floor start, ceil end)
    /// — identical policy to `AppAudioManifestBridge.makeDestination`.
    private static func makeDestination(startUs: Int64, durationUs: Int64) throws -> ProjectTimeRange {
        guard startUs >= 0, durationUs > 0 else {
            throw AppRealtimeAudioIntegrationError.invalidDestination(
                itemIndex: 0, startUs: startUs, durationUs: durationUs)
        }
        let endUs = startUs.addingReportingOverflow(durationUs)
        guard !endUs.overflow,
              let startTicks = Slice005TickProjection.floorTicks(startUs),
              let endTicks = Slice005TickProjection.ceilTicks(endUs.partialValue),
              let start = try? ProjectTime(ticks: startTicks),
              let end = try? ProjectTime(ticks: endTicks),
              let range = try? ProjectTimeRange(start: start, end: end) else {
            throw AppRealtimeAudioIntegrationError.invalidDestination(
                itemIndex: 0, startUs: startUs, durationUs: durationUs)
        }
        return range
    }

    /// Map app video `volume` (0...1) to canonical `AudioGain`, fail-closed (mirrors AppAudioManifestBridge).
    private static func makeGain(volume: Float) throws -> AudioGain {
        let v = Double(volume)
        guard v.isFinite, v >= 0.0, v <= 1.0 else {
            throw AppRealtimeAudioIntegrationError.invalidGain(itemIndex: 0, volume: v)
        }
        let raw = Int64((v * Double(AudioGain.unityRaw)).rounded())
        guard let gain = try? AudioGain(raw: raw) else {
            throw AppRealtimeAudioIntegrationError.invalidGain(itemIndex: 0, volume: v)
        }
        return gain
    }
}
