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
// Lifetime (CP7.8 §9): each produced `RuntimeTextureHandle` retains its `CVPixelBuffer` + `CVMetalTexture`;
// the engine holds the whole binding set until its command buffer completes. We also blit the
// CoreVideo-mapped texture into an OWNED `.private` texture (mirrors `ExportVideoFrameProvider`), so a
// held/cached frame survives across reader advances without aliasing a recycled IOSurface.
//
// Thread-confinement: NOT thread-safe. One instance per render path, all calls on that path's serial
// render queue (same confinement as the rest of the Next bridge).

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
    case ownedTextureAllocFailed(URL)

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
        case .ownedTextureAllocFailed(let u): return "Next video texture: owned MTLTexture alloc failed for \(u.lastPathComponent)."
        }
    }
}

/// One video block's per-frame texture resolver. Owns an `AVAssetReader` + a `CVMetalTextureCache` and
/// hands back a `(descriptor, handle)` for a requested scene-local time. Forward-only, hold-last.
final class NextVideoTextureResolver {

    /// One resolved frame: the value descriptor for the canonical graph + the runtime GPU handle.
    struct Frame {
        let descriptor: ResolvedDynamicTextureInput
        let handle: RuntimeTextureHandle
    }

    /// CMTime timescale (matches `NextVideoBlockResolver` / `ExportVideoFrameProvider`).
    private static let timescale: CMTimeScale = 600

    let blockID: String
    let mediaReference: String
    private let window: NextVideoWindow
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
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

    /// CP7.8 per-PTS cache: the last produced `Frame` keyed by the chosen sample's PTS. When a frame
    /// selects the SAME decoded sample (held tail / repeated scrub / fps mismatch) we return the cached
    /// owned-texture frame — no re-decode, no re-blit. Reset on reader (re)start.
    private var cachedPTS: CMTime = .invalid
    private var cachedFrame: Frame?

    #if DEBUG
    /// Test-only: number of actual GPU texture realizations (cache misses).
    private(set) var realizeCountForTesting = 0
    #endif

    init(blockID: String, mediaReference: String, window: NextVideoWindow,
         device: MTLDevice, commandQueue: MTLCommandQueue) {
        self.blockID = blockID
        self.mediaReference = mediaReference
        self.window = window
        self.device = device
        self.commandQueue = commandQueue
    }

    deinit { teardown() }

    func teardown() {
        reader?.cancelReading()
        reader = nil; output = nil; last = nil; pending = nil
        isPrepared = false; isFinished = true
        cachedFrame = nil; cachedPTS = .invalid
        // Flush the texture cache so its mapped textures are released.
        if let cache = textureCache { CVMetalTextureCacheFlush(cache, 0) }
    }

    // MARK: - Resolve

    /// CP7.8-CORR F1/F2: the last realized frame, if any. The bounded preview path presents this when a
    /// cold decode is over budget this tick (soft-skip), so the UI never blocks on N simultaneous decodes.
    var lastCachedFrame: Frame? { cachedFrame }

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
        return cachedFrame != nil ? false : true                         // no cache yet ⇒ must realize once
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

        // Per-PTS cache: same chosen sample → return the cached owned-texture frame (no re-realize).
        if let cachedFrame, cachedPTS.isValid, chosen.pts == cachedPTS {
            return cachedFrame
        }

        let frame = try realize(from: chosen.pixelBuffer, pts: chosen.pts)
        cachedFrame = frame
        cachedPTS = chosen.pts
        #if DEBUG
        realizeCountForTesting += 1
        #endif
        return frame
    }

    // MARK: - Prepare / decode (mirror NextVideoBlockResolver, but Metal-compatible output)

    private func startReader(fromSeconds: Double) throws {
        reader?.cancelReading()
        reader = nil; output = nil; last = nil; pending = nil; isFinished = false
        cachedFrame = nil; cachedPTS = .invalid

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
