#if DEBUG
import Foundation
import Metal

// MARK: - CP7.8-CORR: media file-stat cache (main-thread fix B)
//
// `NextPreviewKey.init` previously called `FileManager.attributesOfItem` for EVERY bound media block on
// EVERY `draw(in:)` — for 6 videos that was ~12 synchronous disk stats/frame ≈ 30ms on the MAIN thread
// (device-measured), the dominant cause of the "ui тормозит" lag the render-queue probe could not see.
//
// A resolved media URL points at a file that only changes when the user (re)assigns media — never within
// a playback/scrub frame stream. So the (size, mtime) identity is cached by path and reused every frame;
// the editor calls `invalidate(path:)` when it (re)resolves a media URL, so a genuine file-identity change
// still flows into `mediaKey` (which gates decode/context rebuild). Thread-safe (init can run off-main).
final class NextMediaStatCache {
    static let shared = NextMediaStatCache()
    struct Stat: Equatable { let size: Int64; let mtime: Double }
    private let lock = NSLock()
    private var cache: [String: Stat] = [:]

    /// The cached (size, mtime) for `path`, computing + caching it once on a miss. No per-frame disk IO
    /// after the first stat for a given path.
    func stat(path: String) -> Stat {
        lock.lock()
        if let hit = cache[path] { lock.unlock(); return hit }
        lock.unlock()
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let s = Stat(
            size: (attrs?[.size] as? NSNumber)?.int64Value ?? -1,
            mtime: (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1)
        lock.lock(); cache[path] = s; lock.unlock()
        return s
    }

    /// MAIN-THREAD-SAFE lookup that NEVER touches disk: returns the cached (size, mtime) or a `-1` sentinel
    /// on a miss. The draw path uses this so `makeNextBridgeInputs` / `NextPreviewKey` perform NO disk IO;
    /// the real stat is warmed off-main by `stat(path:)` at URL resolution. A miss (sentinel) on the very
    /// first frame after resolve is harmless: the identity converges once the warm completes, and a
    /// sentinel→real transition changes `mediaKey` (a one-time rebuild), never a per-frame cost.
    func cachedOnly(path: String) -> Stat {
        lock.lock(); defer { lock.unlock() }
        return cache[path] ?? Stat(size: -1, mtime: -1)
    }

    /// Drop the cached stat for `path` so the next `stat(path:)` re-reads from disk. Called by the editor
    /// when a media URL is (re)resolved (the only moment the file identity can change).
    func invalidate(path: String) { lock.lock(); cache[path] = nil; lock.unlock() }
    func invalidateAll() { lock.lock(); cache.removeAll(); lock.unlock() }
}

// MARK: - CP3: DEBUG-only Next preview cache + scheduler
//
// Splits the CP2 per-draw pipeline into:
//   - a PREPARED template context (heavy: decode/convert/assets/session) cached per identity, and
//   - a per-frame render (light: evaluate/resolve/compile/execute) served from a bounded frame cache.
//
// Threading model (crash-safe): ALL controller mutable state (epoch, key, context, frameCache,
// stats) is touched ONLY on the main thread. The serial render queue runs pure rendering from
// values passed into the closure — it never reads `self`'s mutable state and never calls
// `DispatchQueue.main.sync` (which deadlocked under scrub load in the first cut). The non-Sendable
// `MetalRenderSession` lives inside the context and every `execute` runs on the SAME serial queue,
// so renders are serialized (no concurrent/reentrant Metal access). Results hop back to main; a
// completion tagged with a stale epoch is dropped before publication.

/// Identity that must be stable for a prepared context to be reused. Any change rebuilds it.
/// CP4: includes EVERY bound block (media identity + placement), sorted by blockID for determinism.
struct NextPreviewKey: Equatable {
    /// Per-block media identity (placement-free).
    struct BlockMedia: Equatable {
        let blockID: String
        let mediaPath: String
        let mediaSize: Int64
        let mediaMTime: Double
        /// CP7: video trim window (winStart, winEnd) in seconds; nil for a photo. A trim change does
        /// not alter the file (path/size/mtime stay the same), so it MUST participate in the media
        /// identity — otherwise a re-trim would reuse the stale decoded resolver / cached frames.
        let videoWindow: VideoWindowKey?

        struct VideoWindowKey: Equatable { let winStart: Double; let winEnd: Double }
    }
    /// Per-block placement.
    struct BlockPlacement: Equatable {
        let blockID: String
        let fitModeRaw: String
        let offsetX: Double
        let offsetY: Double
        let userScale: Double
        let rotationDegrees: Double
    }

    let sceneTypeId: String
    let variantOverrides: [String: String]
    /// CP7.5: the timeline span participates in the media identity because `decodeMedia` resolves the
    /// stretched `timelineSpan` (two-clock). A scene stretched after the Next context is cached must
    /// re-enter decode (new span → new evaluator window) instead of reusing the old nominal context.
    let timelineDurationFrames: Int?
    let blockMedia: [BlockMedia]        // sorted by blockID
    let blockPlacements: [BlockPlacement] // sorted by blockID

    init?(inputs: NextBridgeInputs) {
        guard !inputs.blocks.isEmpty else { return nil }
        self.sceneTypeId = inputs.sceneTypeId
        self.variantOverrides = inputs.variantOverrides
        self.timelineDurationFrames = inputs.timelineDurationFrames
        let sorted = inputs.blocks.sorted { $0.blockID < $1.blockID }
        self.blockMedia = sorted.map { b in
            // CP7.8-CORR (main-thread fix B): PURE / value-only — NO FileManager, NO disk IO here. The per-
            // frame `attributesOfItem` previously cost ~30ms for 6 videos (12 stats/frame) on the MAIN
            // thread → "ui тормозит". The (size, mtime) media identity is now computed OFF the main thread
            // when the URL resolves and carried in `NextBridgeBlock.mediaSize/mediaMTime`; the key just
            // reads those values. A real file-identity change still flows into `mediaKey` because the
            // editor recomputes the stat (and bumps the carried values) on URL resolve / refresh.
            BlockMedia(
                blockID: b.blockID, mediaPath: b.mediaURL.path,
                mediaSize: b.mediaSize,
                mediaMTime: b.mediaMTime,
                videoWindow: b.video.map { BlockMedia.VideoWindowKey(winStart: $0.winStart, winEnd: $0.winEnd) })
        }
        self.blockPlacements = sorted.map { b in
            BlockPlacement(
                blockID: b.blockID, fitModeRaw: b.placement.fitModeRaw,
                offsetX: b.placement.offsetX, offsetY: b.placement.offsetY,
                userScale: b.placement.userScale, rotationDegrees: b.placement.rotationDegrees)
        }
    }

    /// Placement-FREE identity: the heavy decoded media (compiled.tve + per-block photos + authored
    /// assets) depends only on scene + variant + per-block media — NOT on placement. A placement
    /// change on any block keeps the same `mediaKey`, so the expensive decode is reused.
    struct MediaKey: Equatable {
        let sceneTypeId: String
        let variantOverrides: [String: String]
        let timelineDurationFrames: Int?
        let blockMedia: [BlockMedia]
    }
    var mediaKey: MediaKey {
        MediaKey(
            sceneTypeId: sceneTypeId,
            variantOverrides: variantOverrides,
            timelineDurationFrames: timelineDurationFrames,
            blockMedia: blockMedia)
    }
}

/// CP5: identity of a MULTI-SCENE timeline that must be stable for the prepared timeline context to
/// be reused. Any change (scene set, per-scene media/placement/variant, or a boundary transition)
/// rebuilds it. Composed from the per-scene `NextPreviewKey`s plus the boundary transition descriptors.
struct NextTimelineKey: Equatable {
    struct TransitionKey: Equatable {
        let typeRaw: String
        let direction: String?
        let durationFrames: Int
        let easingRaw: String
    }
    let sceneKeys: [NextPreviewKey]      // one per scene, in timeline order
    let transitions: [TransitionKey]     // n-1, in boundary order
    let fps: Int

    init?(inputs: NextBridgeTimelineInputs) {
        guard inputs.scenes.count >= 2 else { return nil }
        var keys: [NextPreviewKey] = []
        for ts in inputs.scenes {
            guard let k = NextPreviewKey(inputs: ts.scene) else { return nil }
            keys.append(k)
        }
        self.sceneKeys = keys
        self.transitions = inputs.scenes.dropLast().map { ts in
            let t = ts.transitionToNext
            return TransitionKey(
                typeRaw: t?.typeRaw ?? "none", direction: t?.direction,
                durationFrames: t?.durationFrames ?? 0, easingRaw: t?.easingRaw ?? "linear")
        }
        self.fps = inputs.fps
    }

    /// Placement-FREE media identity for the whole timeline: the per-scene media keys + transitions.
    /// A placement-only change on any scene keeps this stable, so the heavy per-scene decode is reused.
    struct MediaKey: Equatable {
        let sceneMediaKeys: [NextPreviewKey.MediaKey]
        let transitions: [TransitionKey]
        let fps: Int
    }
    var mediaKey: MediaKey {
        MediaKey(sceneMediaKeys: sceneKeys.map { $0.mediaKey }, transitions: transitions, fps: fps)
    }
}

struct NextPreviewStats {
    var prepareHits = 0, prepareMisses = 0
    var frameHits = 0, frameMisses = 0
    var staleDropped = 0
    var lastRenderMs = 0.0
    var lastPrepareMs = 0.0
}

/// Owns the prepared context + a bounded frame cache + a serial render queue. Main-thread only for
/// all state; the render queue is pure compute.
final class NextPreviewController {

    enum Outcome {
        case frame(NextBridgeBGRAFrame)
        case failure(Error)
    }

    /// CP7.7-next GPU-direct result: a checked-out canvas texture (the editor presents it + checks it back
    /// in on the presentation command buffer's completion handler), a soft skip (pool momentarily
    /// exhausted — present the last good frame, NOT an error), or a hard failure (fail-closed).
    enum TextureOutcome {
        case texture(CanvasTextureHandle)
        case skipped                 // pool exhausted this tick → keep last frame, do NOT show an error
        case failure(Error)
    }

    /// CP7.7-next: internal sentinel — the texture pool was momentarily exhausted (all textures in
    /// flight). NOT a real error: the caller presents the last good frame and waits for one to free up.
    private struct PoolExhausted: Error {}

    private let device: MTLDevice
    private let maxCachedFrames: Int

    // --- main-thread-only state ---
    private var key: NextPreviewKey?
    private var context: NextPreparedContext?
    private var frameCache: [Int: NextBridgeBGRAFrame] = [:]
    private var lruOrder: [Int] = []
    /// The most recent successfully rendered frame (any key). Presented by `draw(in:)` on a cache
    /// MISS so a live gesture shows each just-rendered frame immediately, instead of stalling until
    /// the key settles — the stream of new placement keys otherwise outran the cache and the frame
    /// was rendered but never presented (preview only updated at gesture end). Main-thread only.
    private(set) var latestFrame: NextBridgeBGRAFrame?
    /// CP7.7-next GPU-direct: the most recent successfully rendered canvas-texture handle (any key),
    /// presented on a cache miss so a live gesture shows each just-rendered frame immediately — the
    /// texture analogue of `latestFrame`. Main-thread only. The editor checks it IN after presentation.
    private(set) var latestTextureHandle: CanvasTextureHandle?
    /// CP7.7-next: bounded canvas-texture pool, created lazily on the render queue (needs the engine
    /// device from the shared session). Its own methods are thread-safe (checkin fires from a GPU thread).
    private var texturePool: CanvasTexturePool?
    /// Trailing-coalesced latest GPU-direct request (single-scene + timeline share one, like inFlight).
    private var pendingTextureRequest: (inputs: NextBridgeInputs, completion: (TextureOutcome) -> Void)?
    private var pendingTimelineTextureRequest: (inputs: NextBridgeTimelineInputs, completion: (TextureOutcome) -> Void)?
    /// Bumped on every identity change. A completion carrying an old epoch is dropped.
    private var epoch: UInt64 = 0
    /// CP7.7-next: the current preview epoch (bumped on every MEDIA identity change). The editor watches it
    /// to drop its held GPU front buffer across a media change, so a stale texture is never re-presented.
    var previewEpoch: UInt64 { epoch }
    /// True while a prepare/render is in flight for the current epoch (avoids piling up work).
    private var inFlight = false
    /// Trailing-coalesced latest request that arrived while a render was in flight. Fired on completion.
    private var pendingRequest: (inputs: NextBridgeInputs, completion: (Outcome) -> Void)?
    /// Counts identity (placement/scrub) changes; prerender only runs once this stops advancing
    /// (gesture settled), so live gestures get the render queue to themselves.
    private var keyChangesSincePrerender: UInt64 = 0
    private var lastPrerenderKeyChanges: UInt64 = 0

    /// CP7.8-CORR F1/F2: cold video decodes allowed per PREVIEW tick during an ACTIVE scrub/gesture. Caps
    /// the per-frame decode work so a multi-video hard scrub never serializes N far decodes in one tick
    /// (the 3.3 s 6-video stall). Over budget, a video reuses its last-good texture (soft-skip); it catches
    /// up over subsequent ticks. When the gesture SETTLES the render uses `.max` (exact frame). Tunable.
    private static let scrubColdDecodeBudget = 2

    /// The decode budget for the request being dispatched. Bounded ONLY during an interactive SCRUB:
    /// `!isPlaying` AND the key advanced since the last settle (a live gesture). During PLAYBACK
    /// (`isPlaying`) it is UNBOUNDED so every video advances each tick (a cheap forward decode — bounding
    /// playback starved videos: "рывками / не запускаются"). Settled (not playing, key stable) is also
    /// unbounded → exact frame.
    private func previewDecodeBudget(isPlaying: Bool) -> Int {
        guard !isPlaying else { return .max }
        return keyChangesSincePrerender != lastPrerenderKeyChanges ? Self.scrubColdDecodeBudget : .max
    }
    /// Last play/scrub mode the editor reported (so a trailing-coalesced re-fire uses the current mode).
    private var lastIsPlaying = false

    private let renderQueue = DispatchQueue(label: "com.animi.next-preview.render", qos: .userInitiated)
    private(set) var stats = NextPreviewStats()

    /// The single shared render session, built lazily on the render queue (reused across contexts).
    private var sessionBox: NextSessionBox?
    /// Render-queue-only: cached decoded media (placement-free) + the media key it was decoded for.
    /// Reused across placement changes so dragging media does NOT re-decode the photo.
    private var decodedMedia: NextDecodedMedia?
    private var decodedMediaKey: NextPreviewKey.MediaKey?

    // --- CP5 timeline-mode state (main-thread only, mirrors the single-scene fields) ---
    private var timelineKey: NextTimelineKey?
    private var timelineContext: NextTimelinePreparedContext?
    /// Render-queue-only: cached per-scene decoded media (placement-free) + the timeline media key.
    private var timelineDecoded: [NextDecodedMedia]?
    private var timelineDecodedKey: NextTimelineKey.MediaKey?

    // 8 cached BGRA8 frames at canvas size (1080×1920 ≈ 8.3MB) ≈ 66MB ceiling — bounded well under
    // the process memory limit (the OOM that killed the app came from full-res photo decode + a
    // large frame cache; both are now capped).
    init(device: MTLDevice, maxCachedFrames: Int = 8) {
        self.device = device
        self.maxCachedFrames = max(2, maxCachedFrames)
    }

    /// Invalidate everything. Main-thread only.
    func invalidateAll() {
        dispatchPrecondition(condition: .onQueue(.main))
        epoch &+= 1
        key = nil; context = nil
        frameCache.removeAll(); lruOrder.removeAll()
        latestFrame = nil
        inFlight = false
        pendingRequest = nil
        keyChangesSincePrerender = 0; lastPrerenderKeyChanges = 0
        prerenderToken?.cancel(); prerenderToken = nil
        timelineKey = nil; timelineContext = nil
        timelineDecoded = nil; timelineDecodedKey = nil
        // CP7.7-next: drop the latest GPU texture reference + pending texture requests. The pool drains
        // its textures; any handle still being presented checks in (no-op) when its present completes.
        latestTextureHandle = nil
        pendingTextureRequest = nil; pendingTimelineTextureRequest = nil
        texturePool?.clear()
    }

    /// CP7.7-next: free preview GPU resources under memory pressure (mirrors the Data path cleanup).
    func releaseTextureResources() {
        dispatchPrecondition(condition: .onQueue(.main))
        latestTextureHandle = nil
        texturePool?.clearFront()
        texturePool?.clear()
    }

    /// CP7.7-next: `handle` was just promoted to the displayed front buffer AND a present command buffer
    /// sampling it was just committed — count one in-flight GPU read. Thread-safe; called from `draw(in:)`.
    /// The matching `presentReadCompleted` MUST fire from that command buffer's completion handler.
    func markTextureFrontAndPresenting(_ handle: CanvasTextureHandle) {
        texturePool?.setFront(handle)
        texturePool?.retainForPresent(handle)
    }

    /// CP7.7-next: a re-present of the SAME front buffer (no new render) committed another read — count it
    /// (no front change). Thread-safe; called from `draw(in:)`.
    func markTexturePresentingAgain(_ handle: CanvasTextureHandle) {
        texturePool?.retainForPresent(handle)
    }

    /// CP7.7-next: a present command buffer sampling `handle` COMPLETED (GPU finished reading) — drop one
    /// in-flight read. The texture becomes reuse-eligible only once it is no longer front AND reads hit 0.
    /// Thread-safe — fires from the present command buffer completion handler on a GPU queue thread.
    func presentReadCompleted(_ handle: CanvasTextureHandle) {
        texturePool?.releaseAfterPresent(handle)
    }

    /// CP7.7-next: drop the front mark (e.g. teardown). The texture stays non-reusable until reads drain.
    func clearTextureFront() {
        texturePool?.clearFront()
    }

    /// CP7.7-next: return a checked-out texture that was rendered but NEVER presented (stale epoch, or a
    /// pending handle the editor superseded before drawing it). It is idle → safe to reuse. Thread-safe.
    func releaseUnpresentedTexture(_ handle: CanvasTextureHandle) {
        texturePool?.releaseUnpresented(handle)
    }

    /// Request the frame for `inputs.frameIndex`. Returns a cached frame synchronously (fast scrub),
    /// or nil after scheduling an async render whose result is delivered to `completion` on main.
    func requestFrame(_ inputs: NextBridgeInputs, completion: @escaping (Outcome) -> Void) -> NextBridgeBGRAFrame? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let newKey = NextPreviewKey(inputs: inputs) else {
            completion(.failure(NextBridgeError.mediaResolveFailed("unresolved media file")))
            return nil
        }

        if newKey != key {
            let mediaChanged = (newKey.mediaKey != key?.mediaKey)
            key = newKey
            // Context is placement-dependent → must rebuild on ANY key change. Frame cache is keyed
            // by frameIndex for the CURRENT placement → invalid on any change.
            context = nil
            frameCache.removeAll(); lruOrder.removeAll()
            pendingRequest = nil
            prerenderToken?.cancel(); prerenderToken = nil
            keyChangesSincePrerender &+= 1

            // Epoch is bumped ONLY on MEDIA identity change. A placement-only change (the live
            // gesture stream, many keys/sec) must NOT bump epoch — otherwise every in-flight render
            // is marked stale by the next gesture tick before it can publish (18ms render vs a new
            // key every ~16ms), so NO frame ever reaches the screen until the gesture stops. By not
            // bumping epoch for placement, each completed placement render publishes as `latestFrame`
            // and present-on-miss shows it live. The render reads the latest placement via the
            // captured `inputs`, so the newest placement still wins.
            if mediaChanged {
                latestFrame = nil
                epoch &+= 1
                inFlight = false      // a stale media render's completion will be epoch-dropped
            }
        }

        let frameIndex = max(0, inputs.frameIndex)

        // Fast path: context ready + frame cached → synchronous.
        if context != nil, let cached = frameCache[frameIndex] {
            stats.frameHits += 1
            touchLRU(frameIndex)
            if stats.frameHits % 30 == 0 { logStats("scrub") }
            return cached
        }

        // Trailing-coalesce: if a render is already in flight, stash THIS request as the pending
        // latest. When the current render completes it fires the pending one immediately, so a live
        // gesture (rotate/scale/move) keeps catching up to the newest placement instead of stalling
        // until the next draw (which made dragging feel laggy even though each render is ~18ms).
        if inFlight {
            stats.frameMisses += 1
            pendingRequest = (inputs, completion)
            return nil
        }

        stats.frameMisses += 1
        let renderEpoch = epoch
        let renderKey = newKey
        let captured = inputs
        let mediaKey = newKey.mediaKey
        // Per-block placements for assemble() — placement-only changes reuse decoded pixels.
        let placementByBlockID = Dictionary(uniqueKeysWithValues: inputs.blocks.map { ($0.blockID, $0.placement) })
        let existingContext = context          // value captured on main; immutable once built
        inFlight = true
        if existingContext == nil { stats.prepareMisses += 1 } else { stats.prepareHits += 1 }

        // Pure render on the serial queue: state touched here (sessionBox, decodedMedia*) is ONLY
        // ever touched on this serial queue.
        renderQueue.async { [weak self, device] in
            guard let self else { return }
            typealias RenderOK = (frame: NextBridgeBGRAFrame, ctx: NextPreparedContext?, prepMs: Double, renderMs: Double)
            // Drain per-render Metal allocations (textures, command buffers, IOSurfaces) immediately.
            // Without this, a SLOW sustained gesture (many renders over seconds, each in its own GCD
            // block) lets autoreleased Metal objects accumulate until the 3GB limit → OOM kill. A
            // fast flick produces fewer renders and didn't hit it — matching the slow-crash symptom.
            let result: Result<RenderOK, Error> = autoreleasepool {
                do {
                    // Shared session — built once on this queue, reused.
                    let box: NextSessionBox
                    if let existing = self.sessionBox { box = existing }
                    else { box = try NextSingleSceneBridge.makeSession(device: device); self.sessionBox = box }

                    var preparedNow: NextPreparedContext? = nil
                    var prepMs = 0.0
                    let ctx: NextPreparedContext
                    if let existingContext {
                        ctx = existingContext
                    } else {
                        let t0 = Self.nowMs()
                        // Reuse decoded media (placement-free) if the media key matches — this is the
                        // expensive photo/asset decode. A placement-only change hits this fast path.
                        let decoded: NextDecodedMedia
                        if let cached = self.decodedMedia, self.decodedMediaKey == mediaKey {
                            decoded = cached
                        } else {
                            decoded = try NextSingleSceneBridge.decodeMedia(captured)
                            self.decodedMedia = decoded
                            self.decodedMediaKey = mediaKey
                        }
                        // Cheap: convert + window for THIS placement, reusing decoded pixels.
                        let prepared = try NextSingleSceneBridge.assemble(decoded: decoded, placementByBlockID: placementByBlockID, sessionBox: box)
                        prepMs = Self.nowMs() - t0
                        preparedNow = prepared
                        ctx = prepared
                    }
                    let t1 = Self.nowMs()
                    let frame = try NextSingleSceneBridge.renderFrameBGRA(context: ctx, frameIndex: frameIndex)
                    return .success((frame, preparedNow, prepMs, Self.nowMs() - t1))
                } catch {
                    return .failure(error)
                }
            }

            DispatchQueue.main.async {
                self.inFlight = false
                let epochStale = (renderEpoch != self.epoch)
                if epochStale { self.stats.staleDropped += 1 }
                if !epochStale {
                    switch result {
                    case .success(let r):
                        // Only adopt the prepared context / frame-cache entry if the key still
                        // matches — during a live gesture the placement key moves on while this
                        // render was in flight, and caching a stale-placement context/frame would
                        // make later requests reuse the WRONG placement. `latestFrame` is always
                        // published (present-on-miss shows the most recent rendered placement).
                        let keyCurrent = (self.key == renderKey)
                        if keyCurrent {
                            if let prepared = r.ctx { self.context = prepared; self.stats.lastPrepareMs = r.prepMs }
                            self.insertFrame(frameIndex, r.frame)
                        }
                        self.stats.lastRenderMs = r.renderMs
                        self.latestFrame = r.frame
                        completion(.frame(r.frame))
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
                // Drain the trailing-coalesced latest request (live gesture catch-up).
                if let pending = self.pendingRequest {
                    self.pendingRequest = nil
                    _ = self.requestFrame(pending.inputs, completion: pending.completion)
                }
            }
        }
        return nil
    }

    // MARK: - CP7.7-next: GPU-direct (single-scene) — renders into a pooled canvas texture, no readback

    /// Request the frame for `inputs.frameIndex` as a GPU-direct canvas texture (no CPU readback/Data).
    /// Returns nil after scheduling an async render whose checked-out texture is delivered to `completion`
    /// on main; the editor presents it and checks it back in on the present command buffer's completion.
    /// Mirrors `requestFrame`'s epoch / latest-wins / trailing-coalesce; there is NO per-index texture
    /// cache (the bounded pool holds only the in-flight set) — scrub already missed the frame cache, and
    /// static playback's win is the reused prepared context, not a cached output texture.
    func requestTexture(_ inputs: NextBridgeInputs, isPlaying: Bool = false, completion: @escaping (TextureOutcome) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        lastIsPlaying = isPlaying
        guard let newKey = NextPreviewKey(inputs: inputs) else {
            completion(.failure(NextBridgeError.mediaResolveFailed("unresolved media file")))
            return
        }

        if newKey != key {
            let mediaChanged = (newKey.mediaKey != key?.mediaKey)
            key = newKey
            context = nil
            frameCache.removeAll(); lruOrder.removeAll()
            pendingRequest = nil; pendingTextureRequest = nil
            prerenderToken?.cancel(); prerenderToken = nil
            keyChangesSincePrerender &+= 1
            if mediaChanged {
                latestFrame = nil
                latestTextureHandle = nil   // stale GPU frame: do not present across a media change
                epoch &+= 1
                inFlight = false
            }
        }

        let frameIndex = max(0, inputs.frameIndex)

        // Trailing-coalesce while a render is in flight (no synchronous texture cache to hit).
        if inFlight {
            stats.frameMisses += 1
            pendingTextureRequest = (inputs, completion)
            return
        }

        stats.frameMisses += 1
        let renderEpoch = epoch
        let renderKey = newKey
        let captured = inputs
        let mediaKey = newKey.mediaKey
        let placementByBlockID = Dictionary(uniqueKeysWithValues: inputs.blocks.map { ($0.blockID, $0.placement) })
        let existingContext = context
        let decodeBudget = previewDecodeBudget(isPlaying: lastIsPlaying)   // CP7.8-CORR F1/F2: bounded only during interactive scrub
        inFlight = true
        if existingContext == nil { stats.prepareMisses += 1 } else { stats.prepareHits += 1 }

        renderQueue.async { [weak self, device] in
            guard let self else { return }
            typealias RenderOK = (handle: CanvasTextureHandle, ctx: NextPreparedContext?, prepMs: Double, renderMs: Double)
            let result: Result<RenderOK, Error> = autoreleasepool {
                do {
                    let box: NextSessionBox
                    if let existing = self.sessionBox { box = existing }
                    else { box = try NextSingleSceneBridge.makeSession(device: device); self.sessionBox = box }

                    var preparedNow: NextPreparedContext? = nil
                    var prepMs = 0.0
                    let ctx: NextPreparedContext
                    if let existingContext {
                        ctx = existingContext
                    } else {
                        let t0 = Self.nowMs()
                        let decoded: NextDecodedMedia
                        if let cached = self.decodedMedia, self.decodedMediaKey == mediaKey {
                            decoded = cached
                        } else {
                            decoded = try NextSingleSceneBridge.decodeMedia(captured)
                            self.decodedMedia = decoded
                            self.decodedMediaKey = mediaKey
                        }
                        let prepared = try NextSingleSceneBridge.assemble(decoded: decoded, placementByBlockID: placementByBlockID, sessionBox: box)
                        prepMs = Self.nowMs() - t0
                        preparedNow = prepared
                        ctx = prepared
                    }
                    // Lazily build the pool on the engine device (same device the session renders with).
                    let pool: CanvasTexturePool
                    if let existing = self.texturePool { pool = existing }
                    else { let p = CanvasTexturePool(device: box.metalDevice); self.texturePool = p; pool = p }
                    let (cw, ch) = ctx.canvasPixelSize
                    guard let handle = pool.checkout(width: cw, height: ch) else {
                        // Pool exhausted: all textures in flight. SOFT skip — present the last good frame,
                        // never allocate past the bound, never block, never show an error.
                        throw PoolExhausted()
                    }
                    let t1 = Self.nowMs()
                    do {
                        try NextSingleSceneBridge.renderFramePreview(context: ctx, frameIndex: frameIndex, into: handle.texture, decodeBudget: decodeBudget)
                    } catch {
                        // Render failed: return the never-presented (idle) handle so its slot is not leaked.
                        pool.releaseUnpresented(handle)
                        throw error
                    }
                    pool.markRendered(handle)
                    return .success((handle, preparedNow, prepMs, Self.nowMs() - t1))
                } catch {
                    return .failure(error)
                }
            }

            DispatchQueue.main.async {
                self.inFlight = false
                let epochStale = (renderEpoch != self.epoch)
                if epochStale { self.stats.staleDropped += 1 }
                if !epochStale {
                    switch result {
                    case .success(let r):
                        let keyCurrent = (self.key == renderKey)
                        if keyCurrent, let prepared = r.ctx { self.context = prepared; self.stats.lastPrepareMs = r.prepMs }
                        self.stats.lastRenderMs = r.renderMs
                        // Replace latest: the OLD latest handle has either already been presented + checked
                        // in, or will be when its present completes — we never check it in here (that would
                        // race with an in-flight present). We just stop referencing it.
                        self.latestTextureHandle = r.handle
                        completion(.texture(r.handle))
                    case .failure(let error):
                        if error is PoolExhausted { completion(.skipped) }   // soft: keep last frame
                        else { completion(.failure(error)) }
                    }
                } else {
                    // Stale epoch: the rendered handle is not adopted. It was never presented (idle) but is
                    // still checked out — explicitly return it so its pool slot is not leaked.
                    if case .success(let r) = result { self.texturePool?.releaseUnpresented(r.handle) }
                }
                if let pending = self.pendingTextureRequest {
                    self.pendingTextureRequest = nil
                    self.requestTexture(pending.inputs, isPlaying: self.lastIsPlaying, completion: pending.completion)
                }
            }
        }
    }

    /// Trailing-coalesced latest TIMELINE request (separate from the single-scene `pendingRequest`).
    private var pendingTimelineRequest: (inputs: NextBridgeTimelineInputs, completion: (Outcome) -> Void)?

    /// CP5: request the frame for a MULTI-SCENE timeline at `inputs.nominalFrameIndex`. Mirrors
    /// `requestFrame`'s epoch / bounded frame cache / latest-wins / trailing-coalesce machinery, but
    /// builds a merged multi-scene context and renders `.single`/`.transition` frames through Next.
    /// Returns a cached frame synchronously (fast scrub) or nil after scheduling an async render.
    func requestTimelineFrame(_ inputs: NextBridgeTimelineInputs, completion: @escaping (Outcome) -> Void) -> NextBridgeBGRAFrame? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let newKey = NextTimelineKey(inputs: inputs) else {
            completion(.failure(NextBridgeError.multiSceneUnsupported(sceneItemCount: inputs.scenes.count)))
            return nil
        }

        if newKey != timelineKey {
            let mediaChanged = (newKey.mediaKey != timelineKey?.mediaKey)
            timelineKey = newKey
            timelineContext = nil
            frameCache.removeAll(); lruOrder.removeAll()
            pendingTimelineRequest = nil
            prerenderToken?.cancel(); prerenderToken = nil
            keyChangesSincePrerender &+= 1
            // Epoch bumps only on a MEDIA change (same reasoning as the single-scene path: a
            // placement-only stream must not stale-drop every in-flight render before it publishes).
            if mediaChanged {
                latestFrame = nil
                epoch &+= 1
                inFlight = false
            }
        }

        let frameIndex = max(0, inputs.nominalFrameIndex)

        if timelineContext != nil, let cached = frameCache[frameIndex] {
            stats.frameHits += 1
            touchLRU(frameIndex)
            if stats.frameHits % 30 == 0 { logStats("timeline-scrub") }
            return cached
        }

        if inFlight {
            stats.frameMisses += 1
            pendingTimelineRequest = (inputs, completion)
            return nil
        }

        stats.frameMisses += 1
        let renderEpoch = epoch
        let renderKey = newKey
        let captured = inputs
        let mediaKey = newKey.mediaKey
        let existingContext = timelineContext
        inFlight = true
        if existingContext == nil { stats.prepareMisses += 1 } else { stats.prepareHits += 1 }

        renderQueue.async { [weak self, device] in
            guard let self else { return }
            typealias RenderOK = (frame: NextBridgeBGRAFrame, ctx: NextTimelinePreparedContext?, prepMs: Double, renderMs: Double)
            let result: Result<RenderOK, Error> = autoreleasepool {
                do {
                    let box: NextSessionBox
                    if let existing = self.sessionBox { box = existing }
                    else { box = try NextSingleSceneBridge.makeSession(device: device); self.sessionBox = box }

                    var preparedNow: NextTimelinePreparedContext? = nil
                    var prepMs = 0.0
                    let ctx: NextTimelinePreparedContext
                    if let existingContext {
                        ctx = existingContext
                    } else {
                        let t0 = Self.nowMs()
                        // Reuse per-scene decoded media (placement-free) if the timeline media key matches.
                        let decoded: [NextDecodedMedia]
                        if let cached = self.timelineDecoded, self.timelineDecodedKey == mediaKey {
                            decoded = cached
                        } else {
                            decoded = try NextTimelineBridge.decodeTimeline(captured)
                            self.timelineDecoded = decoded
                            self.timelineDecodedKey = mediaKey
                        }
                        let prepared = try NextTimelineBridge.assembleTimeline(decoded: decoded, inputs: captured, sessionBox: box)
                        prepMs = Self.nowMs() - t0
                        preparedNow = prepared
                        ctx = prepared
                    }
                    let t1 = Self.nowMs()
                    let frame = try NextTimelineBridge.renderFrameBGRA(context: ctx, frameIndex: frameIndex)
                    return .success((frame, preparedNow, prepMs, Self.nowMs() - t1))
                } catch {
                    return .failure(error)
                }
            }

            DispatchQueue.main.async {
                self.inFlight = false
                let epochStale = (renderEpoch != self.epoch)
                if epochStale { self.stats.staleDropped += 1 }
                if !epochStale {
                    switch result {
                    case .success(let r):
                        let keyCurrent = (self.timelineKey == renderKey)
                        if keyCurrent {
                            if let prepared = r.ctx { self.timelineContext = prepared; self.stats.lastPrepareMs = r.prepMs }
                            self.insertFrame(frameIndex, r.frame)
                        }
                        self.stats.lastRenderMs = r.renderMs
                        self.latestFrame = r.frame
                        completion(.frame(r.frame))
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
                if let pending = self.pendingTimelineRequest {
                    self.pendingTimelineRequest = nil
                    _ = self.requestTimelineFrame(pending.inputs, completion: pending.completion)
                }
            }
        }
        return nil
    }

    // MARK: - CP7.7-next: GPU-direct (timeline) — renders into a pooled canvas texture, no readback

    /// CP7.7-next: timeline GPU-direct request. Mirrors `requestTexture` (single-scene) but uses the
    /// timeline key/context/bridge. Returns nil after scheduling an async render.
    func requestTimelineTexture(_ inputs: NextBridgeTimelineInputs, isPlaying: Bool = false, completion: @escaping (TextureOutcome) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        lastIsPlaying = isPlaying
        guard let newKey = NextTimelineKey(inputs: inputs) else {
            completion(.failure(NextBridgeError.multiSceneUnsupported(sceneItemCount: inputs.scenes.count)))
            return
        }

        if newKey != timelineKey {
            let mediaChanged = (newKey.mediaKey != timelineKey?.mediaKey)
            timelineKey = newKey
            timelineContext = nil
            frameCache.removeAll(); lruOrder.removeAll()
            pendingTimelineRequest = nil; pendingTimelineTextureRequest = nil
            prerenderToken?.cancel(); prerenderToken = nil
            keyChangesSincePrerender &+= 1
            if mediaChanged {
                latestFrame = nil
                latestTextureHandle = nil
                epoch &+= 1
                inFlight = false
            }
        }

        let frameIndex = max(0, inputs.nominalFrameIndex)

        if inFlight {
            stats.frameMisses += 1
            pendingTimelineTextureRequest = (inputs, completion)
            return
        }

        stats.frameMisses += 1
        let renderEpoch = epoch
        let renderKey = newKey
        let captured = inputs
        let mediaKey = newKey.mediaKey
        let existingContext = timelineContext
        let decodeBudget = previewDecodeBudget(isPlaying: lastIsPlaying)   // CP7.8-CORR F1/F2: bounded only during interactive scrub
        inFlight = true
        if existingContext == nil { stats.prepareMisses += 1 } else { stats.prepareHits += 1 }

        renderQueue.async { [weak self, device] in
            guard let self else { return }
            typealias RenderOK = (handle: CanvasTextureHandle, ctx: NextTimelinePreparedContext?, prepMs: Double, renderMs: Double)
            let result: Result<RenderOK, Error> = autoreleasepool {
                do {
                    let box: NextSessionBox
                    if let existing = self.sessionBox { box = existing }
                    else { box = try NextSingleSceneBridge.makeSession(device: device); self.sessionBox = box }

                    var preparedNow: NextTimelinePreparedContext? = nil
                    var prepMs = 0.0
                    let ctx: NextTimelinePreparedContext
                    if let existingContext {
                        ctx = existingContext
                    } else {
                        let t0 = Self.nowMs()
                        let decoded: [NextDecodedMedia]
                        if let cached = self.timelineDecoded, self.timelineDecodedKey == mediaKey {
                            decoded = cached
                        } else {
                            decoded = try NextTimelineBridge.decodeTimeline(captured)
                            self.timelineDecoded = decoded
                            self.timelineDecodedKey = mediaKey
                        }
                        let prepared = try NextTimelineBridge.assembleTimeline(decoded: decoded, inputs: captured, sessionBox: box)
                        prepMs = Self.nowMs() - t0
                        preparedNow = prepared
                        ctx = prepared
                    }
                    let pool: CanvasTexturePool
                    if let existing = self.texturePool { pool = existing }
                    else { let p = CanvasTexturePool(device: box.metalDevice); self.texturePool = p; pool = p }
                    let (cw, ch) = ctx.canvasPixelSize
                    guard let handle = pool.checkout(width: cw, height: ch) else {
                        // Pool exhausted: SOFT skip (keep last frame), matching the single-scene path —
                        // NOT a visible render failure. The `.failure(PoolExhausted)` is mapped to `.skipped`.
                        throw PoolExhausted()
                    }
                    let t1 = Self.nowMs()
                    do {
                        try NextTimelineBridge.renderFramePreview(context: ctx, frameIndex: frameIndex, into: handle.texture, decodeBudget: decodeBudget)
                    } catch {
                        // Render failed: return the never-presented (idle) handle so its slot is not leaked.
                        pool.releaseUnpresented(handle)
                        throw error
                    }
                    pool.markRendered(handle)
                    return .success((handle, preparedNow, prepMs, Self.nowMs() - t1))
                } catch {
                    return .failure(error)
                }
            }

            DispatchQueue.main.async {
                self.inFlight = false
                let epochStale = (renderEpoch != self.epoch)
                if epochStale { self.stats.staleDropped += 1 }
                if !epochStale {
                    switch result {
                    case .success(let r):
                        let keyCurrent = (self.timelineKey == renderKey)
                        if keyCurrent, let prepared = r.ctx { self.timelineContext = prepared; self.stats.lastPrepareMs = r.prepMs }
                        self.stats.lastRenderMs = r.renderMs
                        self.latestTextureHandle = r.handle
                        completion(.texture(r.handle))
                    case .failure(let error):
                        if error is PoolExhausted { completion(.skipped) }   // soft: keep last frame
                        else { completion(.failure(error)) }
                    }
                } else {
                    // Stale epoch: explicitly return the unadopted (idle) handle so its slot is not leaked.
                    if case .success(let r) = result { self.texturePool?.releaseUnpresented(r.handle) }
                }
                if let pending = self.pendingTimelineTextureRequest {
                    self.pendingTimelineTextureRequest = nil
                    self.requestTimelineTexture(pending.inputs, isPlaying: self.lastIsPlaying, completion: pending.completion)
                }
            }
        }
    }

    /// Atomic cancellation token shared with the running prerender batch (off-main safe).
    private final class CancelToken { private let l = NSLock(); private var c = false
        var cancelled: Bool { l.lock(); defer { l.unlock() }; return c }
        func cancel() { l.lock(); c = true; l.unlock() } }
    private var prerenderToken: CancelToken?

    /// Pre-render a bounded sequence for smoother playback. Main-thread only; renders missing frames
    /// on the serial queue and inserts them on main. Skips while a foreground render is in flight.
    func prerenderSequence(from startFrame: Int, count: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !inFlight, let ctx = context else { return }
        // Gesture-settled gate: only prerender once the identity (placement/scrub) has stopped
        // changing since the last attempt. During a live move/scale/rotate the key advances every
        // tick, so this stays a no-op and the serial render queue is reserved for the live frame.
        guard keyChangesSincePrerender == lastPrerenderKeyChanges else {
            lastPrerenderKeyChanges = keyChangesSincePrerender
            return
        }
        let total = max(1, ctx.totalFrames)
        let targets = (0..<max(0, count)).map { (startFrame + $0) % total }.filter { frameCache[$0] == nil }
        guard !targets.isEmpty else { return }
        // Cancel any prior batch and start a fresh token (cancellation is off-main safe).
        prerenderToken?.cancel()
        let token = CancelToken()
        prerenderToken = token
        let renderEpoch = epoch
        renderQueue.async { [weak self] in
            guard let self else { return }
            for f in targets {
                if token.cancelled { return }   // identity changed → stop the batch promptly
                // Drain Metal allocations per prerendered frame (same OOM reason as the main render).
                guard let frame = autoreleasepool(invoking: { try? NextSingleSceneBridge.renderFrameBGRA(context: ctx, frameIndex: f) }) else { continue }
                DispatchQueue.main.async {
                    guard renderEpoch == self.epoch else { return }
                    self.insertFrame(f, frame)
                }
            }
        }
    }

    /// CP7.5: TIMELINE prerender — the multi-scene equivalent of `prerenderSequence`. Without this a
    /// timeline scrub/playback rendered EVERY frame cold (no cache warming), which dominated the
    /// stretched-timeline slowdown. Mirrors the single-scene gating/cancellation/epoch exactly but uses
    /// `timelineContext` + the timeline bridge. Frame index is the NOMINAL project frame.
    func prerenderTimelineSequence(from startFrame: Int, count: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !inFlight, let ctx = timelineContext else { return }
        guard keyChangesSincePrerender == lastPrerenderKeyChanges else {
            lastPrerenderKeyChanges = keyChangesSincePrerender
            return
        }
        let total = max(1, ctx.totalFrames)
        let targets = (0..<max(0, count)).map { (startFrame + $0) % total }.filter { frameCache[$0] == nil }
        guard !targets.isEmpty else { return }
        prerenderToken?.cancel()
        let token = CancelToken()
        prerenderToken = token
        let renderEpoch = epoch
        renderQueue.async { [weak self] in
            guard let self else { return }
            for f in targets {
                if token.cancelled { return }
                guard let frame = autoreleasepool(invoking: { try? NextTimelineBridge.renderFrameBGRA(context: ctx, frameIndex: f) }) else { continue }
                DispatchQueue.main.async {
                    guard renderEpoch == self.epoch else { return }
                    self.insertFrame(f, frame)
                }
            }
        }
    }

    func logStats(_ tag: String) {
        let s = stats
        NSLog("[CP3 NextPreview] \(tag) prepare(hit=\(s.prepareHits) miss=\(s.prepareMisses)) frame(hit=\(s.frameHits) miss=\(s.frameMisses)) stale=\(s.staleDropped) lastPrep=\(String(format: "%.1f", s.lastPrepareMs))ms lastRender=\(String(format: "%.1f", s.lastRenderMs))ms cached=\(frameCache.count)")
    }

    // MARK: - Private (main-thread only)

    private func insertFrame(_ index: Int, _ frame: NextBridgeBGRAFrame) {
        if frameCache[index] == nil { lruOrder.append(index) }
        frameCache[index] = frame
        touchLRU(index)
        while frameCache.count > maxCachedFrames, let evict = lruOrder.first {
            lruOrder.removeFirst()
            frameCache.removeValue(forKey: evict)
        }
    }

    private func touchLRU(_ index: Int) {
        if let i = lruOrder.firstIndex(of: index) { lruOrder.remove(at: i) }
        lruOrder.append(index)
    }

    private static func nowMs() -> Double { Date().timeIntervalSince1970 * 1000.0 }
}
#endif
