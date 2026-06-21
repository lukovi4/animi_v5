#if DEBUG
import Foundation
import Metal

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
            let attrs = try? FileManager.default.attributesOfItem(atPath: b.mediaURL.path)
            return BlockMedia(
                blockID: b.blockID, mediaPath: b.mediaURL.path,
                mediaSize: (attrs?[.size] as? NSNumber)?.int64Value ?? -1,
                mediaMTime: (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1,
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
    /// Bumped on every identity change. A completion carrying an old epoch is dropped.
    private var epoch: UInt64 = 0
    /// True while a prepare/render is in flight for the current epoch (avoids piling up work).
    private var inFlight = false
    /// Trailing-coalesced latest request that arrived while a render was in flight. Fired on completion.
    private var pendingRequest: (inputs: NextBridgeInputs, completion: (Outcome) -> Void)?
    /// Counts identity (placement/scrub) changes; prerender only runs once this stops advancing
    /// (gesture settled), so live gestures get the render queue to themselves.
    private var keyChangesSincePrerender: UInt64 = 0
    private var lastPrerenderKeyChanges: UInt64 = 0

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
