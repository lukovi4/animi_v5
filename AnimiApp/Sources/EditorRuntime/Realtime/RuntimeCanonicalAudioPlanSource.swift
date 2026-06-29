import Foundation
import AnimiEngineCore

/// Slice-005 Stage C.5 — the production `ProductionPreviewAudioPlanSource` backed by the live
/// `EditorRuntime`. It builds a REAL canonical `AudioPlan` synchronously from current editor state and
/// resolves each audio source to a file URL for the canonical renderer/cache.
///
/// Pipeline (synchronous, no renderd video media needed for AUDIO coverage):
///   editorState.canonicalTimeline.sceneItems  ─▶ minimal canonical VIDEO manifest (scene spans only)
///   editorState.canonicalTimeline.allAudioItems ─▶ AppAudioManifestBridge.Input[]
///                                                 ─▶ AppAudioManifestBridge (populated AudioManifest)
///   imported asset URL via mediaLocator + registry ─▶ ResolvedAudioSourceDescriptor (probe-light)
///                                                 ─▶ AppAudioEvaluationBridge.evaluateWholeProject ─▶ AudioPlan
///
/// Empty audio → `nil` (silent). A project that HAS audio → a non-empty plan, or a typed failure — NEVER
/// an unavailable render pipeline, NEVER a silent `nil`. `.bundled` SFX (no canonical preview URL
/// resolution) fails closed via `audioAssetUnresolvable`.
@MainActor
final class RuntimeCanonicalAudioPlanSource: ProductionPreviewAudioPlanSource {

    weak var runtime: EditorRuntime?
    /// Injected synchronous URL resolver `(assetId, fallbackStoragePath) -> URL?`. The
    /// `ProjectMediaLocator` protocol method is `async`; this synchronous resolver keeps
    /// `currentAudioPlan()` non-async (the controller's play path is synchronous). Defaults to a
    /// path-based resolution off the registry storagePath.
    private let resolveURL: (_ assetId: ProjectAssetID, _ fallbackStoragePath: String, _ registry: ProjectAssetRegistry) -> URL?
    /// The most recent source-URL map produced by `currentAudioPlan`, consumed by the render pipeline.
    private(set) var resolvedSourcesByID: [String: CanonicalResolvedAudioSource] = [:]

    /// Stage-9.2: the async app-side probe for the REAL audio-track duration of a video-original source.
    private let durationProbe = VideoOriginalAudioDurationProbe()
    /// Stage-9.2: MainActor mirror of the warm-up result for video-original sources, keyed by the asset id.
    /// Holds BOTH the mediaLocator-resolved URL (the SAME URL the visual preview uses) AND the real
    /// audio-track duration (seconds). `currentAudioPlan()` reads ONLY this for video-original — never the
    /// sync `defaultResolveURL` path-guess — so the probe URL and `resolvedSourcesByID` URL are identical.
    private var videoOriginalWarmByAsset: [ProjectAssetID: (url: URL, seconds: Double)] = [:]
    /// Stage-9.2: injectable async URL resolver (production = `session.mediaLocator.absoluteURL`, the visual
    /// path). Tests inject a fake to assert the locator URL — not `defaultResolveURL` — is used.
    private let mediaLocatorURL: (_ mediaRef: MediaRef, _ registry: ProjectAssetRegistry) async throws -> URL

    init(
        runtime: EditorRuntime?,
        resolveURL: @escaping (_ assetId: ProjectAssetID, _ fallbackStoragePath: String, _ registry: ProjectAssetRegistry) -> URL? = RuntimeCanonicalAudioPlanSource.defaultResolveURL,
        mediaLocatorURL: ((_ mediaRef: MediaRef, _ registry: ProjectAssetRegistry) async throws -> URL)? = nil
    ) {
        self.mediaLocatorURL = mediaLocatorURL ?? { [weak runtime] mediaRef, registry in
            guard let runtime else { throw AppRealtimeAudioIntegrationError.mediaUnavailable(sourceRaw: mediaRef.assetId.rawValue.uuidString) }
            return try await runtime.session.mediaLocator.absoluteURL(for: mediaRef, registry: registry)
        }
        self.runtime = runtime
        self.resolveURL = resolveURL
    }

    /// Default synchronous URL resolution: registry storagePath (or fallback) relative to the user's
    /// project storage root. Mirrors `FileProjectMediaStore.absoluteURL(forRelativePath:)` without the
    /// async protocol hop. Returns `nil` if no base directory / path is available. `nonisolated` — it
    /// touches no actor state, so it can be the default for the non-isolated `resolveURL` closure.
    nonisolated static func defaultResolveURL(
        assetId: ProjectAssetID, fallbackStoragePath: String, registry: ProjectAssetRegistry
    ) -> URL? {
        let relativePath = registry.storagePath(for: assetId) ?? fallbackStoragePath
        guard !relativePath.isEmpty else { return nil }
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        else { return nil }
        // Mirror `FileProjectMediaStore.absoluteURL(forRelativePath:)` EXACTLY: the base is
        // `<appSupport>/<projectsDirectoryName>` (the real constant is "AnimiProjects", NOT the literal
        // "Projects" — using the wrong name yielded `mediaUnavailable` on device → fallback). The storagePath
        // already carries the `Media/UserMedia/...` suffix.
        return base
            .appendingPathComponent(FileProjectPersistenceStore.projectsDirectoryName)
            .appendingPathComponent(relativePath)
    }

    /// Stage-9.2: warm up the REAL audio-track durations for the current project's video-original sources by
    /// resolving each block's URL and awaiting the async probe, then mirroring the results onto the MainActor.
    /// Call this BEFORE `currentAudioPlan()` so the first build has the real durations (video-original is
    /// fail-closed without them). Safe to call repeatedly (cached). No-op when nothing is loaded.
    func warmUpVideoOriginalDurations() async {
        guard let runtime, let state = runtime.session.state else { return }
        let timeline = state.canonicalTimeline
        let registry = runtime.selfHealedRegistry()
        // Collect distinct video MediaRefs (by asset id) for visible video slots.
        var refs: [ProjectAssetID: MediaRef] = [:]
        for item in timeline.sceneItems {
            guard let sceneState = state.draft.sceneInstanceStates[item.id],
                  let slots = sceneState.mediaSlotsByBlockId else { continue }
            for (_, slot) in slots where slot.visibility && slot.mediaRef.mediaKind == .video {
                refs[slot.mediaRef.assetId] = slot.mediaRef
            }
        }
        for (assetId, mediaRef) in refs where videoOriginalWarmByAsset[assetId] == nil {
            // SAME URL the visual preview uses (mediaLocator), then probe the real audio-track duration by it.
            guard let url = try? await mediaLocatorURL(mediaRef, registry) else { continue }
            guard let seconds = await durationProbe.seconds(for: url) else { continue }
            videoOriginalWarmByAsset[assetId] = (url: url, seconds: seconds)
        }
    }

    #if DEBUG
    /// Test seam: directly seed the warm mirror (URL + seconds) for an asset, so a synchronous
    /// `currentAudioPlan()` build in a unit test uses a known URL/duration without a live probe.
    func _setVideoOriginalWarmForTesting(assetId: ProjectAssetID, url: URL, seconds: Double) {
        videoOriginalWarmByAsset[assetId] = (url: url, seconds: seconds)
    }
    #endif

    /// Resolve one source for the renderer/cache (set by the last `currentAudioPlan`).
    func resolvedSource(for sourceID: AudioSourceID) -> CanonicalResolvedAudioSource? {
        resolvedSourcesByID[sourceID.raw]
    }

    func currentAudioPlan() throws -> AudioPlan? {
        resolvedSourcesByID = [:]
        guard let runtime, let state = runtime.session.state else {
            return nil   // nothing loaded → silent
        }
        let timeline = state.canonicalTimeline

        // 1. App GLOBAL audio items → manifest-bridge inputs + resolve each source URL (imported/bundled).
        let audioItems = timeline.allAudioItems
        let registry = runtime.selfHealedRegistry()
        var inputs: [AppAudioManifestBridge.Input] = []
        var resolved: [String: CanonicalResolvedAudioSource] = [:]
        var durationUsBySource: [String: Int64] = [:]
        for (index, item) in audioItems.enumerated() {
            guard let payload = timeline.audioPayload(for: item.id) else { continue }
            inputs.append(AppAudioManifestBridge.Input(
                index: index,
                startUs: item.startUs ?? 0,
                durationUs: item.durationUs,
                payload: payload))
            // Resolve the source URL (the manifest bridge derives the same source id from assetRef).
            if let (sourceRaw, source) = try resolve(payload: payload, registry: registry) {
                resolved[sourceRaw] = source
                // Carry the REAL per-source duration (µs) so the descriptor is not synthesized.
                durationUsBySource[sourceRaw] = payload.sourceDurationUs
            }
        }

        // 1b. VIDEO-ORIGINAL audio (Slice-005 Stage 0+1): build a canonical video-layer clip + a `.video`
        // scene-payload layer per user video block. The AUDIO path owns its own `.video(VideoBinding)`
        // mirror (the visual bridge stays `.image`); the source mapping is proven equal to the visual
        // `NextVideoTimeMapping` (see `AppVideoOriginalAudioBridge`). Synchronous, fail-closed.
        let videoBuilt = try buildVideoOriginalAudio(timeline: timeline, state: state, registry: registry)
        for vb in videoBuilt {
            resolved[vb.sourceRaw] = CanonicalResolvedAudioSource(url: vb.resolvedURL)
        }

        // No global audio AND no video-original audio → genuinely silent (legitimate silent epoch).
        guard !inputs.isEmpty || !videoBuilt.isEmpty else { return nil }

        // 2. Populated canonical GLOBAL AudioManifest (Stage A), then MERGE the video-original entries.
        // Clamp clip destinations to the project span (sum of scene durations) so an imported track LONGER
        // than the project does not push `destination.end` past the canonical project end (which the
        // `ProjectValidator` rejects with `audioDestinationOutsideProject` → forced legacy fallback).
        let projectEndUs = timeline.totalDurationUs
        let globalManifest = inputs.isEmpty
            ? AudioManifest.empty
            : try AppAudioManifestBridge.buildManifest(
                items: inputs, includeOriginalFromVideoSlots: false, projectEndUs: projectEndUs)
        let audioManifest = Self.mergeVideoOriginal(into: globalManifest, video: videoBuilt)
        if audioManifest.isEmpty { return nil }

        // 3. Source descriptors: global (real duration) + one per video source.
        var descriptors = try Self.makeDescriptors(for: globalManifest, durationUsBySource: durationUsBySource)
        descriptors.append(contentsOf: videoBuilt.map(\.built.descriptor))

        // 4. Minimal canonical VIDEO document from scene spans, with the video-original `.video` layers
        //    injected onto the matching scene payloads (so `AudioEvaluationWindowBuilder` can resolve them).
        let document = try buildMinimalVideoDocument(
            timeline: timeline, videoLayersBySceneID: Self.videoLayersBySceneID(videoBuilt))

        // 5. Canonical window + plan via the Stage-B bridge (uses the canonical AudioEvaluator).
        let window = try AudioEvaluationWindowBuilder.build(
            manifest: injectAudio(document.manifest, audioManifest),
            requirement: try requirement(forDocument: document, audio: audioManifest),
            scenes: document.scenePayloads,
            sourceDescriptors: descriptors)
        let plan = try AudioEvaluator.evaluate(window: window, range: window.coverage)

        self.resolvedSourcesByID = resolved
        return plan
    }

    // MARK: - Video-original audio (Stage 0+1)

    /// One built video-original block plus the resolved file URL for render.
    struct BuiltVideoOriginal {
        let built: AppVideoOriginalAudioBridge.Built
        let sourceRaw: String
        let resolvedURL: URL
    }

    /// Stage-7 S6: the per-scene canonical destination span `[start, end)` in ticks, accumulated with the
    /// SAME basis as the minimal manifest (`buildMinimalVideoDocument`) and `SceneMediaClock.mediaActiveDomain`
    /// — `span_i = max(1, ceilTicks(durationUs_i))`, `start_i = Σ_{k<i} span_k`, `end_i = start_i + span_i`.
    /// FAIL-CLOSED (no silent `-1`/`0`): a non-projectable duration or an overflowing cumulative/end add throws
    /// `.anchorArithmeticOverflow`, exactly like `buildMinimalVideoDocument`. Integer-only.
    static func cumulativeSceneDestinationTicks(_ sceneItems: [TimelineItem]) throws -> [(start: Int64, end: Int64)] {
        var spans: [(start: Int64, end: Int64)] = []
        spans.reserveCapacity(sceneItems.count)
        var acc: Int64 = 0
        for item in sceneItems {
            guard let ceil = Slice005TickProjection.ceilTicks(item.durationUs) else {
                throw AppRealtimeAudioIntegrationError.anchorArithmeticOverflow(
                    detail: "scene destination ticks: ceilTicks(\(item.durationUs)) not representable")
            }
            let span = max(1, ceil)   // mirrors the manifest's `nominalDuration = max(1, ceilTicks)`
            let end = acc.addingReportingOverflow(span)
            guard !end.overflow else {
                throw AppRealtimeAudioIntegrationError.anchorArithmeticOverflow(
                    detail: "scene destination ticks: cumulative end \(acc)+\(span) overflow")
            }
            spans.append((start: acc, end: end.partialValue))
            acc = end.partialValue
        }
        return spans
    }

    /// For each scene item with user video blocks, build the canonical video-original audio pieces. The
    /// scene id mirrors `buildMinimalVideoDocument` (`"scene-\(i)-\(item.id.uuidString)"`); the block's
    /// trim/volume/mute come from `mediaSlotsByBlockId[blockID].videoWindow`; destination = the scene's
    /// project-time span. Fail-closed on any unresolved URL / invalid window.
    private func buildVideoOriginalAudio(
        timeline: CanonicalTimeline, state: EditorState, registry: ProjectAssetRegistry
    ) throws -> [BuiltVideoOriginal] {
        var out: [BuiltVideoOriginal] = []
        let sceneItems = timeline.sceneItems
        // Stage-7 S6 fix: cumulative CANONICAL scene destination ticks using the SAME per-scene
        // `ceilTicks(durationUs)` accumulation as the minimal manifest (`buildMinimalVideoDocument`) and
        // `SceneMediaClock.mediaActiveDomain`. `sceneStartTicks[i] = Σ_{k<i} span_k`, `sceneEndTicks[i] =
        // start + span_i`, where `span_i = max(1, ceilTicks(durationUs_i))` (mirrors the manifest's
        // `nominalDuration`). FAIL-CLOSED — exactly like `buildMinimalVideoDocument:304`: a non-projectable
        // duration or an overflowing cumulative add throws `.anchorArithmeticOverflow`, never a silent
        // `-1`/`0` substitution. Cuts ⇒ boundary postHalf 0, so this equals the media-active domain.
        let sceneSpans: [(start: Int64, end: Int64)] = try Self.cumulativeSceneDestinationTicks(sceneItems)
        for (i, item) in sceneItems.enumerated() {
            // Scene instance state is keyed by the timeline item's INSTANCE id (`item.id`), NOT `payloadId`
            // (`ProjectDraft.sceneInstanceStates` doc: "Key: TimelineItem.id"). Same lookup the rest of the
            // app uses (EditorRuntime/SceneEditController/TimelineCompositionEngine).
            guard let sceneState = state.draft.sceneInstanceStates[item.id],
                  let slots = sceneState.mediaSlotsByBlockId else { continue }
            let sceneStartUs = timeline.computedStartUs(forSceneAt: i)
            let sceneDurationUs = item.durationUs
            let sceneInstanceIDRaw = "scene-\(i)-\(item.id.uuidString)"
            for (blockID, slot) in slots.sorted(by: { $0.key < $1.key }) {
                // VISIBILITY: a hidden video slot contributes NO audio — mirrors the visual fail-closed
                // contract (NextExportInputsBuilder throws `blockHidden`; ExportMediaSnapshot skips hidden).
                guard slot.visibility else { continue }
                guard slot.mediaRef.mediaKind == .video, let win = slot.videoWindow else { continue }
                // STAGE-9.2: use ONLY the warm mirror (mediaLocator URL + real probed duration) for
                // video-original — the SAME URL the visual preview uses. On a miss, kick the async warm-up and
                // FAIL CLOSED for this block (no `defaultResolveURL` path-guess, no `winEnd` fallback); the
                // canonical start path awaits warm-up first, so a normal Play has it.
                guard let warm = videoOriginalWarmByAsset[slot.mediaRef.assetId] else {
                    let probe = durationProbe
                    let resolve = mediaLocatorURL
                    let mediaRef = slot.mediaRef
                    let assetId = slot.mediaRef.assetId
                    Task { [weak self] in
                        guard let url = try? await resolve(mediaRef, registry),
                              let s = await probe.seconds(for: url) else { return }
                        await MainActor.run { self?.videoOriginalWarmByAsset[assetId] = (url: url, seconds: s) }
                    }
                    throw AppRealtimeAudioIntegrationError.audioAssetUnresolvable(
                        detail: "video-original \(blockID): mediaLocator URL/real duration not warmed yet (fail-closed)")
                }
                let url = warm.url
                // AUDIO-INTERNAL media reference (NOT claimed equal to the visual `cp4-`/`cp5-s<i>-` ref):
                // it only needs to be consistent between the clip's `.videoLayerMedia(media)` and the layer's
                // `VideoBinding.media`, which the evaluator asserts. Namespaced per scene+block, unique.
                let mediaReferenceRaw = "audio.videoLayer:\(i):\(blockID)"
                // Block active interval within the scene. Per-block authored timing (blockStartFrame > 0 /
                // partial activeRange end) lives in the compiled template and is NOT synchronously reachable
                // from the editor-state audio plan source — the shipping user-video preview case is a
                // SCENE-FILLING block, i.e. `[0, sceneDuration)`. We use that interval here; authored partial
                // block timing for user video is a documented follow-up (it would narrow this interval).
                let blockStartUsInScene: Int64 = 0
                let blockEndUsInScene: Int64 = sceneDurationUs
                // S6 fix: canonical destination ticks == media-active domain for this scene (cuts).
                // Checked, fail-closed (see `cumulativeSceneDestinationTicks`); `i` is a valid index here.
                let sStartTicks = sceneSpans[i].start
                let sEndTicks = sceneSpans[i].end
                // STAGE-9.2: the REAL audio-track duration comes from the SAME warm entry as `url` (probed by
                // the mediaLocator URL) — descriptor duration and `resolvedURL` share one URL, no split paths.
                let built = try AppVideoOriginalAudioBridge.build(.init(
                    blockID: blockID,
                    sceneInstanceIDRaw: sceneInstanceIDRaw,
                    mediaReferenceRaw: mediaReferenceRaw,
                    winStart: win.trimStart, winEnd: win.trimEnd,
                    volume: win.volume, isMuted: win.isMuted,
                    sceneStartUs: sceneStartUs, sceneDurationUs: sceneDurationUs,
                    sceneStartTicks: sStartTicks, sceneEndTicks: sEndTicks,
                    realAudioTrackDurationSeconds: warm.seconds,
                    blockStartUsInScene: blockStartUsInScene, blockEndUsInScene: blockEndUsInScene))
                out.append(BuiltVideoOriginal(built: built, sourceRaw: built.sourceRaw, resolvedURL: url))
            }
        }
        return out
    }

    /// Merge video-original source/track/clip entries into a (possibly empty) global manifest.
    static func mergeVideoOriginal(into manifest: AudioManifest, video: [BuiltVideoOriginal]) -> AudioManifest {
        guard !video.isEmpty else { return manifest }
        let sources = manifest.sources + video.map(\.built.source)
        let tracks = manifest.tracks + video.map(\.built.track)
        let clips = manifest.clips + video.map(\.built.clip)
        return AudioManifest(sources: sources, tracks: tracks, clips: clips)
    }

    /// Group the built `.video` layers by their scene instance id, for payload injection.
    static func videoLayersBySceneID(_ video: [BuiltVideoOriginal]) -> [String: [SceneLayer]] {
        var byScene: [String: [SceneLayer]] = [:]
        for vb in video {
            byScene[vb.built.sceneInstanceID.raw, default: []].append(vb.built.layer)
        }
        return byScene
    }

    // MARK: - Source resolution

    private func resolve(
        payload: AudioPayload, registry: ProjectAssetRegistry
    ) throws -> (sourceRaw: String, source: CanonicalResolvedAudioSource)? {
        guard let assetRef = payload.assetRef else { return nil }
        switch assetRef {
        case .bundled(let id):
            // Try to resolve the bundled SFX to a Bundle resource URL. If it isn't found, fail VISIBLY
            // with a typed error (which triggers the legacy fallback) — never a silent drop.
            guard let url = Self.bundledResourceURL(id: id) else {
                throw AppRealtimeAudioIntegrationError.audioAssetUnresolvable(
                    detail: "bundled audio '\(id)' not found in app bundle")
            }
            let sourceRaw = "app.audio.source.bundled:\(id)"
            return (sourceRaw, CanonicalResolvedAudioSource(url: url))
        case .imported(let assetId, let storagePath):
            let path = registry.storagePath(for: assetId) ?? storagePath
            guard !path.isEmpty else {
                throw AppRealtimeAudioIntegrationError.audioAssetUnresolvable(detail: "empty storage path for \(assetId.rawValue.uuidString)")
            }
            guard let url = resolveURL(assetId, path, registry) else {
                throw AppRealtimeAudioIntegrationError.mediaUnavailable(sourceRaw: assetId.rawValue.uuidString)
            }
            // The manifest bridge derives the source id as "app.audio.source.imported:<uuid>".
            let sourceRaw = "app.audio.source.imported:\(assetId.rawValue.uuidString)"
            // Source-time (trim) is canonical plan data consumed by the renderer; only the URL is resolved here.
            return (sourceRaw, CanonicalResolvedAudioSource(url: url))
        }
    }

    /// Resolve a bundled audio id to a Bundle resource URL. Tries common audio extensions in the app
    /// bundle; `nil` if not found (caller fails closed visibly).
    nonisolated static func bundledResourceURL(id: String) -> URL? {
        // The id may already include an extension, or be a bare name.
        let bundle = Bundle.main
        if let exact = bundle.url(forResource: id, withExtension: nil) { return exact }
        for ext in ["m4a", "caf", "aac", "mp3", "wav", "aif", "aiff"] {
            if let u = bundle.url(forResource: id, withExtension: ext) { return u }
        }
        return nil
    }

    // MARK: - Descriptors (canonical preview is 48 kHz mono)

    /// Build one descriptor per referenced source. `sourceDuration` is the REAL source duration derived
    /// from the app `AudioPayload.sourceDurationUs` (exact rational seconds `us / 1_000_000`) — never a
    /// synthesized `1/1`. `sampleRate`/`channelLayout` intentionally represent the canonical renderr
    /// output domain (48 kHz mono), which is what the preview mix consumes.
    static func makeDescriptors(
        for manifest: AudioManifest, durationUsBySource: [String: Int64]
    ) throws -> [ResolvedAudioSourceDescriptor] {
        var seen = Set<AudioSourceID>()
        var ordered: [AudioSourceID] = []
        for clip in manifest.clips where seen.insert(clip.sourceID).inserted { ordered.append(clip.sourceID) }
        return try ordered.sorted().map { sourceID in
            guard let durationUs = durationUsBySource[sourceID.raw], durationUs > 0 else {
                throw AppRealtimeAudioIntegrationError.mediaUnsupported(
                    sourceRaw: sourceID.raw, detail: "missing/non-positive source duration")
            }
            return ResolvedAudioSourceDescriptor(
                sourceID: sourceID,
                streamIdentity: try AudioStreamIdentity("stream:\(sourceID.raw)"),
                // Exact real source duration in seconds (auto-reduced); NOT a synthesized 1/1.
                sourceDuration: try RationalSourceTime(numerator: durationUs, denominator: 1_000_000),
                sampleRate: 48_000,
                channelLayout: .mono)
        }
    }

    // MARK: - Minimal canonical video document from scene spans

    private func buildMinimalVideoDocument(
        timeline: CanonicalTimeline,
        videoLayersBySceneID: [String: [SceneLayer]] = [:]
    ) throws -> CanonicalProjectDocument {
        let sceneItems = timeline.sceneItems
        guard !sceneItems.isEmpty else {
            throw AppRealtimeAudioIntegrationError.runtimeStateUnavailable
        }
        var entries: [SceneManifestEntry] = []
        var payloads: [ResolvedScenePayload] = []
        for (i, item) in sceneItems.enumerated() {
            let sceneID = try SceneInstanceID("scene-\(i)-\(item.id.uuidString)")
            let payloadID = try ScenePayloadID("payload-\(i)-\(item.id.uuidString)")
            // Scene duration is a half-open span `[0, durationUs)`; project it with the SHARED outward
            // policy using CEIL so total project coverage can never be shorter than an audio destination's
            // ceil-end for the same `endUs` (blocker 2: no coverage shrink / no audio-tail truncation).
            guard let ticks = Slice005TickProjection.ceilTicks(item.durationUs) else {
                throw AppRealtimeAudioIntegrationError.anchorArithmeticOverflow(detail: "scene.ticks overflow")
            }
            entries.append(SceneManifestEntry(
                id: sceneID, payloadID: payloadID,
                nominalDuration: try TickDuration(ticks: max(1, ticks)),
                postRollCapability: .zero))
            // Stage 0+1: inject the audio-only `.video(VideoBinding)` layers for THIS scene so
            // `AudioEvaluationWindowBuilder` can resolve each video-layer clip's source mapping. Empty for
            // scenes with no user video (global-audio-only path unchanged → still `layers: []`).
            let videoLayers = videoLayersBySceneID[sceneID.raw] ?? []
            payloads.append(ResolvedScenePayload(
                payloadID: payloadID, sceneID: sceneID,
                templateRef: try TemplateReference(catalogID: "preview-audio", sceneID: "s\(i)"),
                layers: videoLayers))
        }
        // Boundary transitions: plain cuts (audio is global; no canonical ramp is invented here).
        let cuts = try (0..<max(0, entries.count - 1)).map { _ in
            AnimiEngineCore.SceneTransition(kind: .cut, duration: .zero, easing: try EasingReference("none"))
        }
        let manifest = CanonicalProjectManifest(
            schemaVersion: CanonicalProjectManifest.supportedSchemaVersion,
            output: OutputContext(canvas: try CanvasSize(width: 1080, height: 1920), frameRate: .fps30),
            scenes: entries, boundaryTransitions: cuts, overlays: [])
        return CanonicalProjectDocument(manifest: manifest, scenePayloads: payloads, overlayPayloads: [])
    }

    private func injectAudio(_ manifest: CanonicalProjectManifest, _ audio: AudioManifest) -> CanonicalProjectManifest {
        CanonicalProjectManifest(
            schemaVersion: manifest.schemaVersion, output: manifest.output, scenes: manifest.scenes,
            boundaryTransitions: manifest.boundaryTransitions, overlays: manifest.overlays, audio: audio)
    }

    private func requirement(
        forDocument document: CanonicalProjectDocument, audio: AudioManifest
    ) throws -> EvaluationWindowRequirement {
        let manifest = injectAudio(document.manifest, audio)
        let index = try TimelineIndex(manifest: manifest)
        let duration = try manifest.projectDuration()
        let coverage = try ProjectTimeRange(start: .zero, end: try ProjectTime(ticks: duration.ticks))
        return try index.requirements(for: coverage)
    }
}
