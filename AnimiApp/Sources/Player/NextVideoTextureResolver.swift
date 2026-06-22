#if DEBUG
import Foundation
import AVFoundation
import CoreVideo
import CoreMedia
import Metal

import AnimiEngineCore
import AnimiEngineRenderModel
import AnimiEngineMetalRender

// MARK: - CP7.8: AnimiEngineNext texture-backed user-video resolver (DEBUG only)
//
// The canonical CP7.8 replacement for `NextVideoBlockResolver`'s CPU bake path. It decodes each video
// frame straight onto the GPU — `CVPixelBuffer → CVMetalTextureCache → MTLTexture` — and hands the Next
// bridge a value-only `ResolvedDynamicTextureInput` (descriptor, no bytes/hash) plus a runtime
// `RuntimeTextureHandle` (the raw texture + retained CoreVideo backing). There is NO `VTCreateCGImage`,
// NO `CGContext` rotate/downsample, NO `Data` copy, NO SHA-256 — the per-frame CPU cost the device
// measurements showed dominant (bake ~34ms p50, hash ~6.5ms) is gone; orientation/downsample run on the
// GPU in the engine's raw→normalized pass.
//
// Timing contract is IDENTICAL to `NextVideoBlockResolver`: trim-only `NextVideoTimeMapping` +
// hold-last PTS lookahead (mirrors `ExportVideoFrameProvider`). The old CPU `NextVideoBlockResolver`
// stays for the parity oracle / tests.
//
// Orientation: the reader yields RAW track-orientation BGRA. The descriptor carries the
// `preferredTransform` quarter-turn (via `NextVideoBlockResolver.quarterTurns`) and the DISPLAY
// (oriented) dimensions; the engine normalization pass applies the quarter-turn (raw → display `.up`),
// matching the CPU `rotateBGRA` oracle exactly.
//
// Lifetime (CP7.8 §9): each produced `RuntimeTextureHandle` retains its `CVPixelBuffer` + `CVMetalTexture`
// (CP7.8-CORR F3 direct-bind — NO owned `.private` texture, NO blit). The engine holds the whole binding
// set until its command buffer completes; the retained `CVMetalTexture` pins the IOSurface so a held/cached
// frame is not aliased to a recycled buffer.
//
// Thread-confinement: NOT thread-safe. One instance per video, all calls serialized by its owner — today
// the preview render queue; under CP7.9 a per-video serial prewarm executor (off the render queue).

/// Typed, visible failure for the CP7.8 texture resolver. No silent fallback.
enum NextVideoTextureResolverError: Error, CustomStringConvertible {
    case missingVideoTrack(URL)
    case readerCreateFailed(URL, Error)
    case cannotAddOutput(URL)
    case readerStartFailed(URL, AVAssetReader.Status, Error?)
    case decodeFailed(URL, Error)
    case noFrameDecoded(URL, targetTime: Double)
    case textureCacheCreateFailed(URL, CVReturn)
    case metalTextureCreateFailed(URL, CVReturn)

    var description: String {
        switch self {
        case .missingVideoTrack(let u): return "Next video texture: no video track in \(u.lastPathComponent)."
        case .readerCreateFailed(let u, let e): return "Next video texture: reader create failed for \(u.lastPathComponent): \(e)."
        case .cannotAddOutput(let u): return "Next video texture: cannot add reader output for \(u.lastPathComponent)."
        case .readerStartFailed(let u, let s, let e): return "Next video texture: reader start failed for \(u.lastPathComponent) (status \(s.rawValue)): \(String(describing: e))."
        case .decodeFailed(let u, let e): return "Next video texture: decode failed for \(u.lastPathComponent): \(e)."
        case .noFrameDecoded(let u, let t): return "Next video texture: no frame decoded for \(u.lastPathComponent) at target \(t)s."
        case .textureCacheCreateFailed(let u, let s): return "Next video texture: CVMetalTextureCache create failed for \(u.lastPathComponent): \(s)."
        case .metalTextureCreateFailed(let u, let s): return "Next video texture: CVMetalTexture create failed for \(u.lastPathComponent): \(s)."
        }
    }
}

/// One resolved video frame: the value descriptor for the canonical graph + the runtime GPU handle.
/// Top-level (CP7.9) so the `NextVideoFrameProvider` seam can name it without coupling to a concrete type.
struct NextVideoFrame {
    let descriptor: ResolvedDynamicTextureInput
    let handle: RuntimeTextureHandle
}

/// CP7.9 seam — the non-decoding-on-render-queue contract the bridge depends on. Today the synchronous
/// `NextVideoTextureResolver` conforms (identical behaviour); Phase 3 swaps in an async prewarm scheduler
/// whose `readyFrame` is non-blocking (binds ready/last-good and schedules the missing decode off-queue).
/// `resolveExact` is the EXACT, synchronous path the EXPORT runner must keep using (never approximate).
protocol NextVideoFrameProvider: AnyObject {
    /// The last realized frame, if any (last-good for the bounded preview soft-skip).
    var lastCachedFrame: NextVideoFrame? { get }
    /// Would resolving this scene-local time require a COLD decode (reader rebuild / forward advance)?
    func wouldColdDecode(scenePlaybackSeconds: Double) -> Bool
    /// EXACT synchronous resolve (export + the current preview path). May block on decode.
    func resolveExact(scenePlaybackSeconds: Double) throws -> NextVideoFrame
}

/// One video block's per-frame texture resolver. Owns an `AVAssetReader` + a `CVMetalTextureCache` and
/// hands back a `NextVideoFrame` for a requested scene-local time. Forward-only, hold-last.
final class NextVideoTextureResolver: NextVideoFrameProvider {

    /// CP7.9: `Frame` kept as a nested alias so existing references compile unchanged.
    typealias Frame = NextVideoFrame

    /// CMTime timescale (matches `NextVideoBlockResolver` / `ExportVideoFrameProvider`).
    private static let timescale: CMTimeScale = 600

    let blockID: String
    let mediaReference: String
    private let window: NextVideoWindow
    private let device: MTLDevice
    private var textureCache: CVMetalTextureCache?

    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var preferredTransform: CGAffineTransform = .identity
    private var quarterTurns: Int = 0

    private struct DecodedSample {
        let pts: CMTime
        let pixelBuffer: CVPixelBuffer
    }
    private var last: DecodedSample?
    private var pending: DecodedSample?
    private var isPrepared = false
    private var isFinished = false
    private var lastPromotedSeconds: Double = -.greatestFiniteMagnitude

    /// CP7.9 per-video frame LRU (was a single-slot per-PTS cache). Holds up to `maxCachedFrames` realized
    /// `Frame`s keyed by sample PTS, MRU-first. A scrub that revisits nearby PTS (or the held tail) hits the
    /// cache instead of re-realizing. Each entry retains its `CVMetalTexture`/`CVPixelBuffer` (pins one
    /// IOSurface), so this per-video bound directly bounds the resolver's GPU memory; the global cap across
    /// all videos is enforced by the owner (Phase 3 scheduler). Cleared on reader (re)start / teardown.
    private struct CachedFrame { let pts: CMTime; let frame: Frame }
    private var lru: [CachedFrame] = []        // index 0 == most-recently-used
    private let maxCachedFrames: Int

    /// Per-video frame-cache bound. Small: a scrub only needs a handful of recent neighbors; each entry
    /// pins an IOSurface. Tunable; the global memory cap is the scheduler's job (Phase 3).
    static let defaultMaxCachedFrames = 6

    #if DEBUG
    /// Test-only: number of actual GPU texture realizations (cache misses).
    private(set) var realizeCountForTesting = 0
    /// Test-only: current LRU occupancy (to pin the per-video bound).
    var cachedFrameCountForTesting: Int { lru.count }
    #endif

    init(blockID: String, mediaReference: String, window: NextVideoWindow, device: MTLDevice,
         maxCachedFrames: Int = NextVideoTextureResolver.defaultMaxCachedFrames) {
        self.blockID = blockID
        self.mediaReference = mediaReference
        self.window = window
        self.device = device
        self.maxCachedFrames = max(1, maxCachedFrames)
    }

    deinit { teardown() }

    func teardown() {
        reader?.cancelReading()
        reader = nil; output = nil; last = nil; pending = nil
        isPrepared = false; isFinished = true
        clearCache()
        // Flush the texture cache so its mapped textures are released.
        if let cache = textureCache { CVMetalTextureCacheFlush(cache, 0) }
    }

    // MARK: - Frame LRU

    /// Drop all cached frames (their CV retains release → IOSurfaces freed). Called on reader (re)start /
    /// teardown / explicit invalidation (epoch change is owner-driven by replacing the resolver).
    private func clearCache() { lru.removeAll(keepingCapacity: true) }

    /// Look up an exact-PTS cached frame, promoting it to MRU. Nil on miss.
    private func cachedFrame(forPTS pts: CMTime) -> Frame? {
        guard let i = lru.firstIndex(where: { $0.pts == pts }) else { return nil }
        if i != 0 { let hit = lru.remove(at: i); lru.insert(hit, at: 0) }
        return lru[0].frame
    }

    /// Insert a freshly realized frame at MRU and evict the LRU tail past the bound (releasing its retain).
    private func insertCache(_ frame: Frame, pts: CMTime) {
        lru.insert(CachedFrame(pts: pts, frame: frame), at: 0)
        if lru.count > maxCachedFrames { lru.removeLast(lru.count - maxCachedFrames) }
    }

    // MARK: - Resolve

    /// CP7.8-CORR F1/F2: the last realized frame (MRU), if any. The bounded preview path presents this when
    /// a cold decode is over budget this tick (soft-skip), so the UI never blocks on N simultaneous decodes.
    var lastCachedFrame: Frame? { lru.first?.frame }

    /// CP7.8-CORR F1/F2: would resolving `scenePlaybackSeconds` require a COLD decode (reader rebuild or a
    /// forward advance to a new sample)? True ⇒ the bounded path should spend budget or soft-skip. False ⇒
    /// the chosen sample is the already-cached PTS (cheap, always allowed).
    func wouldColdDecode(scenePlaybackSeconds: Double) -> Bool {
        let targetSeconds = NextVideoTimeMapping.targetVideoTime(
            scenePlaybackSeconds: scenePlaybackSeconds, winStart: window.winStart, winEnd: window.winEnd)
        if !isPrepared { return true }
        if targetSeconds < lastPromotedSeconds { return true }           // backward → rebuild
        let targetTime = CMTime(seconds: targetSeconds, preferredTimescale: Self.timescale)
        // Cheap iff the currently-promoted sample is still the chosen one (no pending sample <= target).
        if let p = pending, p.pts <= targetTime { return true }          // would advance to a new sample
        return lru.isEmpty ? true : false                                // no cache yet ⇒ must realize once
    }

    /// CP7.9 `NextVideoFrameProvider.resolveExact`: the EXACT synchronous resolve. Delegates to `resolve`.
    /// Export and the current preview path use this; it MAY block on decode (Phase 3 keeps export on this
    /// exact path and routes preview through the async scheduler's non-blocking `readyFrame`).
    func resolveExact(scenePlaybackSeconds: Double) throws -> NextVideoFrame {
        try resolve(scenePlaybackSeconds: scenePlaybackSeconds)
    }

    /// Resolve the texture-backed frame for a SCENE-LOCAL playback time (seconds). Same trim clamp +
    /// hold-last selection as the CPU resolver / TVECore export.
    func resolve(scenePlaybackSeconds: Double) throws -> Frame {
        let targetSeconds = NextVideoTimeMapping.targetVideoTime(
            scenePlaybackSeconds: scenePlaybackSeconds, winStart: window.winStart, winEnd: window.winEnd)
        let targetTime = CMTime(seconds: targetSeconds, preferredTimescale: Self.timescale)

        if !isPrepared || targetSeconds < lastPromotedSeconds {
            try startReader(fromSeconds: targetSeconds)
        }

        while let p = pending, p.pts <= targetTime {
            last = p
            lastPromotedSeconds = p.pts.seconds
            pending = isFinished ? nil : try decodeNextSample()
            if pending == nil { isFinished = true; break }
        }
        if last == nil, let p = pending {
            last = p
            lastPromotedSeconds = p.pts.seconds
            pending = isFinished ? nil : try decodeNextSample()
            if pending == nil { isFinished = true }
        }

        guard let chosen = last else {
            throw NextVideoTextureResolverError.noFrameDecoded(window.url, targetTime: targetSeconds)
        }

        // Per-PTS LRU: a revisited PTS (held tail / repeated or back-and-forth scrub / fps mismatch) hits
        // the cache (and promotes to MRU) → no re-realize.
        if chosen.pts.isValid, let hit = cachedFrame(forPTS: chosen.pts) {
            return hit
        }

        let frame = try realize(from: chosen.pixelBuffer, pts: chosen.pts)
        insertCache(frame, pts: chosen.pts)
        #if DEBUG
        realizeCountForTesting += 1
        #endif
        return frame
    }

    // MARK: - Prepare / decode (mirror NextVideoBlockResolver, but Metal-compatible output)

    private func startReader(fromSeconds: Double) throws {
        reader?.cancelReading()
        reader = nil; output = nil; last = nil; pending = nil; isFinished = false
        clearCache()

        let asset = AVURLAsset(url: window.url)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw NextVideoTextureResolverError.missingVideoTrack(window.url)
        }
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw NextVideoTextureResolverError.readerCreateFailed(window.url, error) }

        // BGRA, Metal-compatible, IOSurface-backed (mirrors ExportVideoFrameProvider).
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false

        let startSeconds = min(max(window.winStart, fromSeconds), window.winEnd)
        let startTime = CMTime(seconds: startSeconds, preferredTimescale: Self.timescale)
        let endTime = CMTime(seconds: window.winEnd, preferredTimescale: Self.timescale)
        reader.timeRange = CMTimeRange(start: startTime, duration: max(.zero, endTime - startTime))

        guard reader.canAdd(output) else { throw NextVideoTextureResolverError.cannotAddOutput(window.url) }
        reader.add(output)
        guard reader.startReading() else {
            throw NextVideoTextureResolverError.readerStartFailed(window.url, reader.status, reader.error)
        }

        self.reader = reader
        self.output = output
        self.preferredTransform = track.preferredTransform
        self.quarterTurns = NextVideoBlockResolver.quarterTurns(for: track.preferredTransform)
        self.isPrepared = true
        self.lastPromotedSeconds = -.greatestFiniteMagnitude

        if textureCache == nil {
            var cache: CVMetalTextureCache?
            let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
            guard status == kCVReturnSuccess, let cache else {
                throw NextVideoTextureResolverError.textureCacheCreateFailed(window.url, status)
            }
            textureCache = cache
        }

        pending = try decodeNextSample()
    }

    private func decodeNextSample() throws -> DecodedSample? {
        guard let output else { return nil }
        guard let sampleBuffer = output.copyNextSampleBuffer() else {
            if let reader, reader.status == .failed {
                throw NextVideoTextureResolverError.decodeFailed(window.url, reader.error ?? NSError(domain: "NextVideoTextureResolver", code: -1))
            }
            return nil
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw NextVideoTextureResolverError.decodeFailed(window.url, NSError(domain: "NextVideoTextureResolver", code: -2, userInfo: [NSLocalizedDescriptionKey: "missing image buffer"]))
        }
        return DecodedSample(pts: pts, pixelBuffer: pixelBuffer)
    }

    // MARK: - GPU realize (CVPixelBuffer → CVMetalTexture, directly bound — CP7.8-CORR F3 Option B)

    /// Map the BGRA `CVPixelBuffer` to a Metal texture via the shared cache and bind it DIRECTLY (no blit,
    /// no second queue, no cross-queue race). The `CVPixelBuffer`+`CVMetalTexture` are retained in the
    /// handle until the engine command buffer completes (§9). The mapped texture is the descriptor's RAW
    /// source (track-native dims); the engine applies the quarter-turn in the normalize pass.
    private func realize(from pixelBuffer: CVPixelBuffer, pts: CMTime) throws -> Frame {
        guard let cache = textureCache else {
            throw NextVideoTextureResolverError.textureCacheCreateFailed(window.url, kCVReturnInvalidArgument)
        }
        let rawW = CVPixelBufferGetWidth(pixelBuffer)
        let rawH = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexOpt: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil, .bgra8Unorm, rawW, rawH, 0, &cvTexOpt)
        guard status == kCVReturnSuccess, let cvTex = cvTexOpt,
              let mappedTexture = CVMetalTextureGetTexture(cvTex) else {
            throw NextVideoTextureResolverError.metalTextureCreateFailed(window.url, status)
        }
        guard mappedTexture.usage.contains(.shaderRead) else {
            // CVMetalTextureCache textures are shaderRead by default; assert it (no silent wrong-usage bind).
            throw NextVideoTextureResolverError.metalTextureCreateFailed(window.url, kCVReturnInvalidArgument)
        }

        // CP7.8-CORR F3 (Option B): bind the CVMetalTexture-mapped texture DIRECTLY — NO owned blit, NO
        // second command queue, NO cross-queue race. Correctness comes from RETAINING the `CVPixelBuffer`
        // + `CVMetalTexture` in the handle's `retain` (threaded to `owner.retainRuntimeBinding`, held until
        // the engine's command buffer COMPLETES — §9). The per-PTS cache holds this Frame, so the mapped
        // texture + its IOSurface stay alive across reader advances (the CVMetalTexture pins the buffer).
        // The CVMetalTextureCache must keep enough buffers in flight; the held-frame cache bounds it to the
        // distinct PTS values actually referenced.
        let turns = ((quarterTurns % 4) + 4) % 4
        let displayW = (turns % 2 == 0) ? rawW : rawH
        let displayH = (turns % 2 == 0) ? rawH : rawW

        // F4: the canonical source id includes the chosen PTS ticks, so distinct video moments have distinct
        // value identities (Rev-2 §6.2). The per-PTS cache keys on the same pts, so a held frame reuses the
        // same id (stable). Format `<ref>@<value>/<timescale>`.
        let ptsTag = "\(pts.value)/\(pts.timescale)"
        let descriptor = try ResolvedDynamicTextureInput(
            id: try PixelInputID("\(mediaReference)@\(ptsTag)"),
            width: displayW, height: displayH,
            bytesFormat: .bgra8, orientation: .up, orientationQuarterTurns: turns)
        let handle = RuntimeTextureHandle(texture: mappedTexture, retain: [pixelBuffer, cvTex])
        return Frame(descriptor: descriptor, handle: handle)
    }
}
#endif
