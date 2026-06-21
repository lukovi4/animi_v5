#if DEBUG
import Foundation
import AVFoundation
import CoreVideo
import CoreGraphics
import CoreMedia
import VideoToolbox

import AnimiEngineCore
import AnimiEngineRenderModel

// MARK: - CP7: AnimiEngineNext user-video frame resolver (DEBUG only)
//
// A narrowly scoped, CPU-only video decoder that feeds AnimiEngineNext the SAME BGRA8 `Data`
// shape it already consumes for photos (`ResolvedPixelInput`). It exists because the existing app
// video infrastructure (`ExportVideoFrameProvider` / `VideoFrameProvider`) hands back `MTLTexture`,
// while the Next bridge takes only owned BGRA8 bytes — so the Next path gets its own decode path
// (owner-approved CP7 design). The old MTLTexture path is untouched and stays the TVECore default.
//
// EXACT timing contract (proven against `ExportVideoSlotsCoordinator.processVisibleSlot` +
// `ExportVideoFrameProvider.texture(forTargetVideoTime:)`, owner-confirmed trim-only — no
// speed/loop/hold for user media):
//   1. project frame → target video time via the CANONICAL `VideoTimelineTimeMapper`:
//        tVideo = trimStart + (sceneFrame - blockStartFrame) / fps,  clamp [winStart, winEnd - 1/600]
//   2. frame selection = HOLD-LAST: the last decoded sample whose pts <= targetTime, using a
//      pending-lookahead exactly like the export provider (no resample/blend — Next gets the nearest
//      preceding decoded frame, matching the export `.usePrev`/hold-last default at integer fps).
//
// Memory: one `AVAssetReader` per video block, sequential forward decode over `[winStart, winEnd]`,
// NO full-video predecode. Only the last + pending CVPixelBuffer are held; each produced frame is a
// freshly-baked BGRA8 `Data` (downsampled to the canvas long edge). Orientation is baked into the
// pixels (the reader yields RAW track orientation; the Next bridge consumes `.up` and ignores
// `VideoPresentationInfo`, so the preferredTransform MUST be applied here).
//
// Random access (scrub): the reader decodes forward-only. Export and playback advance monotonically
// and stream through one reader. A BACKWARD request (scrub left) or a far forward jump rebuilds the
// reader from the new target — `AVAssetReader` cannot rewind, so re-create it with a fresh start
// time. This keeps the common sequential case a single efficient stream while staying correct under
// arbitrary scrub.
//
// Fail-closed: any decode/setup failure throws a typed `NextVideoFrameResolverError`. There is NO
// silent substitution — the caller surfaces the error like every other `NextBridgeError`.

/// Typed, visible failure for the CP7 video resolver. No silent fallback.
enum NextVideoFrameResolverError: Error, CustomStringConvertible {
    case missingVideoTrack(URL)
    case readerCreateFailed(URL, Error)
    case cannotAddOutput(URL)
    case readerStartFailed(URL, AVAssetReader.Status, Error?)
    case decodeFailed(URL, Error)
    case noFrameDecoded(URL, targetTime: Double)
    case pixelBufferToImageFailed(URL)
    case orientationBakeFailed(URL)
    case pixelInput(String)

    var description: String {
        switch self {
        case .missingVideoTrack(let url):
            return "Next video resolver: no video track in \(url.lastPathComponent)."
        case .readerCreateFailed(let url, let e):
            return "Next video resolver: AVAssetReader create failed for \(url.lastPathComponent): \(e)."
        case .cannotAddOutput(let url):
            return "Next video resolver: cannot add reader output for \(url.lastPathComponent)."
        case .readerStartFailed(let url, let status, let e):
            return "Next video resolver: reader start failed for \(url.lastPathComponent) (status \(status.rawValue)): \(String(describing: e))."
        case .decodeFailed(let url, let e):
            return "Next video resolver: decode failed for \(url.lastPathComponent): \(e)."
        case .noFrameDecoded(let url, let t):
            return "Next video resolver: no frame decoded for \(url.lastPathComponent) at target \(t)s."
        case .pixelBufferToImageFailed(let url):
            return "Next video resolver: CVPixelBuffer → CGImage failed for \(url.lastPathComponent)."
        case .orientationBakeFailed(let url):
            return "Next video resolver: orientation bake failed for \(url.lastPathComponent)."
        case .pixelInput(let m):
            return "Next video resolver: pixel input build failed: \(m)."
        }
    }
}

/// App-side trim window the resolver needs, expressed in SECONDS — mirrors `VideoSelection`'s
/// `winStart`/`winEnd` exactly so preview/export feed identical numbers. Carried as primitives so
/// this type stays free of any TVECore dependency (the bridge module must not import TVECore).
struct NextVideoWindow: Equatable {
    /// Resolved local file URL of the video.
    let url: URL
    /// Trim start, seconds (== `VideoSelection.trimStart` == `winStart`).
    let winStart: Double
    /// Trim end, seconds (== `VideoSelection.trimEnd` == `winEnd`).
    let winEnd: Double
}

/// One video block's per-frame BGRA8 resolver. Owns an `AVAssetReader` over the trim window and
/// hands back `ResolvedPixelInput` for a requested project frame. Forward-only, hold-last.
///
/// Thread-confinement: NOT thread-safe. Each instance is owned by exactly ONE render path and all
/// `resolve` calls happen on that path's single serial render queue (preview) or export loop thread
/// — the same confinement the rest of the Next bridge relies on.
final class NextVideoBlockResolver {

    /// CMTime timescale for window/target math (matches `ExportVideoFrameProvider.timescale`).
    private static let timescale: CMTimeScale = 600

    let blockID: String
    let mediaReference: String
    private let window: NextVideoWindow
    /// Long-edge cap for the produced BGRA (canvas long edge). A 4K frame decoded to BGRA8 is huge;
    /// the canvas is the most that is ever visible, so downsample to it (mirrors the photo path).
    private let maxPixelSize: Int

    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    /// preferredTransform of the source track, baked into produced pixels (RAW → display `.up`).
    private var preferredTransform: CGAffineTransform = .identity

    private struct DecodedSample {
        let pts: CMTime
        let pixelBuffer: CVPixelBuffer
    }
    /// Last promoted sample (pts <= last target) and the lookahead pending sample. Mirrors the
    /// export provider's hold-last lookahead so frame selection is byte-for-byte the same policy.
    private var last: DecodedSample?
    private var pending: DecodedSample?
    private var isPrepared = false
    private var isFinished = false
    /// The pts of the currently promoted `last` sample, used to detect a backward request that needs
    /// a reader rebuild (AVAssetReader is forward-only).
    private var lastPromotedSeconds: Double = -.greatestFiniteMagnitude
    /// CP7.5 perf: cache the last BAKED `ResolvedPixelInput` keyed by the chosen sample's PTS. When a
    /// frame selects the SAME decoded sample (held-last tail, repeated scrub at one frame, or the same
    /// 30fps output frame mapping to one 24fps source sample) we return the cached pixels instead of
    /// re-running VTCreateCGImage + CGContext draw + Data copy every call. Reset on reader (re)start.
    private var cachedBakePTS: CMTime = .invalid
    private var cachedBake: ResolvedPixelInput?
    #if DEBUG
    /// Test-only: number of actual bakes (cache misses). A held tail / repeated same-frame request
    /// must not increment this. Pinned by `NextVideoFrameResolverTests`.
    private(set) var bakeCountForTesting = 0
    #endif

    init(blockID: String, mediaReference: String, window: NextVideoWindow, maxPixelSize: Int) {
        self.blockID = blockID
        self.mediaReference = mediaReference
        self.window = window
        self.maxPixelSize = max(16, maxPixelSize)
    }

    deinit { teardown() }

    /// Release the reader + held buffers. Safe to call repeatedly.
    func teardown() {
        reader?.cancelReading()
        reader = nil
        output = nil
        last = nil
        pending = nil
        isPrepared = false
        isFinished = true
        cachedBake = nil
        cachedBakePTS = .invalid
    }

    // MARK: - Prepare

    /// (Re)start the underlying reader so that decoding begins AT OR BEFORE `fromSeconds`. The reader
    /// covers `[max(winStart, fromSeconds), winEnd]`. We clamp the start a hair before the requested
    /// time so the hold-last selection always has a sample with pts <= target available.
    private func startReader(fromSeconds: Double) throws {
        // Tear down any existing reader/buffers (forward-only → backward requires a fresh reader).
        reader?.cancelReading()
        reader = nil; output = nil; last = nil; pending = nil; isFinished = false
        cachedBake = nil; cachedBakePTS = .invalid   // stale across a reader restart

        let asset = AVURLAsset(url: window.url)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw NextVideoFrameResolverError.missingVideoTrack(window.url)
        }

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw NextVideoFrameResolverError.readerCreateFailed(window.url, error) }

        // BGRA output, IOSurface-backed (zero behavioural difference from the export provider's
        // settings — we read bytes on the CPU here rather than wrapping in a Metal texture).
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false

        // Window start: clamp to [winStart, winEnd]. For sequential decode from the top this is
        // winStart (identical to the export provider so PTS values line up exactly). For a scrub
        // seek it starts at the requested time so we do not decode from 0 every scrub.
        let startSeconds = min(max(window.winStart, fromSeconds), window.winEnd)
        let startTime = CMTime(seconds: startSeconds, preferredTimescale: Self.timescale)
        let endTime = CMTime(seconds: window.winEnd, preferredTimescale: Self.timescale)
        reader.timeRange = CMTimeRange(start: startTime, duration: max(.zero, endTime - startTime))

        guard reader.canAdd(output) else { throw NextVideoFrameResolverError.cannotAddOutput(window.url) }
        reader.add(output)
        guard reader.startReading() else {
            throw NextVideoFrameResolverError.readerStartFailed(window.url, reader.status, reader.error)
        }

        self.reader = reader
        self.output = output
        self.preferredTransform = track.preferredTransform
        self.isPrepared = true
        self.lastPromotedSeconds = -.greatestFiniteMagnitude

        // Prime the pending lookahead with the first sample (matches export provider prepare).
        pending = try decodeNextSample()
    }

    /// Decode the next sample buffer into a held CVPixelBuffer + pts. Returns nil at end of stream.
    private func decodeNextSample() throws -> DecodedSample? {
        guard let output else { return nil }
        guard let sampleBuffer = output.copyNextSampleBuffer() else {
            // No more samples; verify it was a clean end, not a decode failure.
            if let reader, reader.status == .failed {
                throw NextVideoFrameResolverError.decodeFailed(window.url, reader.error ?? NSError(domain: "NextVideoBlockResolver", code: -1))
            }
            return nil
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw NextVideoFrameResolverError.decodeFailed(window.url, NSError(domain: "NextVideoBlockResolver", code: -2, userInfo: [NSLocalizedDescriptionKey: "missing image buffer"]))
        }
        return DecodedSample(pts: pts, pixelBuffer: pixelBuffer)
    }

    // MARK: - Resolve

    /// Resolve the BGRA8 frame for a SCENE-LOCAL playback time, in seconds. This is the canonical
    /// evaluator's own `ScenePlaybackTime` for the scene at this frame (transition compression /
    /// scene offsets already applied), which equals `(sceneFrame - blockStart) / fps` for a block
    /// that fills its scene at nominal fps — the exact owner-confirmed contract. Maps to video time
    /// with the same trim clamp + hold-last selection the TVECore export uses.
    func resolve(scenePlaybackSeconds: Double) throws -> ResolvedPixelInput {
        // 1. Scene-local seconds → target video time (trim clamp; same math as the canonical mapper).
        let targetSeconds = NextVideoTimeMapping.targetVideoTime(
            scenePlaybackSeconds: scenePlaybackSeconds, winStart: window.winStart, winEnd: window.winEnd)
        let targetTime = CMTime(seconds: targetSeconds, preferredTimescale: Self.timescale)

        // (Re)start the reader if this is the first request, or the request goes BACKWARD past the
        // currently promoted sample (AVAssetReader is forward-only and cannot rewind). A forward
        // request streams through the existing reader without a rebuild.
        if !isPrepared || targetSeconds < lastPromotedSeconds {
            try startReader(fromSeconds: targetSeconds)
        }

        // 2. Hold-last: promote pending → last while pending.pts <= targetTime (export P0 logic).
        while let p = pending, p.pts <= targetTime {
            last = p
            lastPromotedSeconds = p.pts.seconds
            pending = isFinished ? nil : try decodeNextSample()
            if pending == nil { isFinished = true; break }
        }
        // If we have no last yet (target before first sample), promote the first pending so the
        // very first frame still renders (export provider does the same).
        if last == nil, let p = pending {
            last = p
            lastPromotedSeconds = p.pts.seconds
            pending = isFinished ? nil : try decodeNextSample()
            if pending == nil { isFinished = true }
        }

        guard let chosen = last else {
            throw NextVideoFrameResolverError.noFrameDecoded(window.url, targetTime: targetSeconds)
        }

        // 3. Cache hit: same chosen sample as last bake → return cached pixels (no rebake). The bake
        // (VTCreateCGImage + CGContext rotate/downsample + Data copy) is the dominant per-frame cost;
        // skipping it when the held sample is unchanged removes the held-tail / repeated-scrub overhead.
        if let cachedBake, cachedBakePTS.isValid, chosen.pts == cachedBakePTS {
            return cachedBake
        }

        // 4. Bake orientation + downsample → BGRA8 `Data` → ResolvedPixelInput; cache by sample PTS.
        let baked = try makePixelInput(from: chosen.pixelBuffer)
        cachedBake = baked
        cachedBakePTS = chosen.pts
        #if DEBUG
        bakeCountForTesting += 1
        #endif
        return baked
    }

    // MARK: - BGRA bake (orientation + downsample)

    /// Convert a RAW-orientation BGRA CVPixelBuffer into a display-oriented (`.up`), downsampled,
    /// premultiplied BGRA8 `ResolvedPixelInput`. The reader yields the track's natural orientation;
    /// we apply `preferredTransform` here because the Next bridge consumes `.up` pixels and does NOT
    /// read `VideoPresentationInfo` (the export Metal path applies the transform downstream — for the
    /// Next path there is no such downstream, so it is baked in).
    private func makePixelInput(from pixelBuffer: CVPixelBuffer) throws -> ResolvedPixelInput {
        var cgImageOpt: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImageOpt)
        guard status == noErr, let cgImage = cgImageOpt else {
            throw NextVideoFrameResolverError.pixelBufferToImageFailed(window.url)
        }
        let quarter = Self.quarterTurns(for: preferredTransform)
        let baked = try Self.bake(cgImage: cgImage, quarter: quarter, maxPixelSize: maxPixelSize, url: window.url)
        do {
            let dims = try PixelDimensions(
                width: baked.width, height: baked.height, bytesPerRow: baked.bytesPerRow,
                format: .bgra8, orientation: .up)
            return try ResolvedPixelInput(id: try PixelInputID(mediaReference), dimensions: dims, bytes: Data(baked.bytes))
        } catch {
            throw NextVideoFrameResolverError.pixelInput("\(error)")
        }
    }

    /// PRODUCTION fast bake: rotate (quarter-turn) + downsample a decoded frame in ONE
    /// hardware-accelerated `CGContext.draw` — no per-pixel Swift loop, no intermediate buffers (the
    /// earlier per-pixel rotation caused a ~10× slowdown; this is the corrective single-pass path).
    /// Proven against REAL `preferredTransform` video by the `test_realTransform_*` tests. Returns
    /// top-first `.up` BGRA8 bytes + dims.
    static func bake(cgImage: CGImage, quarter: Int, maxPixelSize: Int, url: URL) throws
        -> (bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int) {
        let rawW = cgImage.width, rawH = cgImage.height
        guard rawW > 0, rawH > 0 else { throw NextVideoFrameResolverError.orientationBakeFailed(url) }
        let turns = ((quarter % 4) + 4) % 4

        // Oriented (display) size: odd turns swap W/H.
        let orientedW = (turns % 2 == 0) ? rawW : rawH
        let orientedH = (turns % 2 == 0) ? rawH : rawW

        // Downsample to the canvas long edge.
        let longEdge = max(orientedW, orientedH)
        let scale = longEdge > maxPixelSize ? Double(maxPixelSize) / Double(longEdge) : 1.0
        let outW = max(1, Int((Double(orientedW) * scale).rounded()))
        let outH = max(1, Int((Double(orientedH) * scale).rounded()))

        let bytesPerRow = outW * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * outH)
        let bmp = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(
            data: &bytes, width: outW, height: outH, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bmp
        ) else { throw NextVideoFrameResolverError.orientationBakeFailed(url) }

        // SINGLE pass: configure the CTM (rotate + scale), then one draw. CoreGraphics does the work.
        ctx.interpolationQuality = .high
        // The draw rect is sized so that, AFTER the rotation set by `configureRotateDraw`, the image
        // fills the output. For even turns the rotated box is (outW,outH); for odd turns the rotation
        // swaps axes so the box is (outH,outW). Either way it equals (scaled) RAW dimensions.
        let drawRect = (turns % 2 == 0)
            ? CGRect(x: 0, y: 0, width: outW, height: outH)
            : CGRect(x: 0, y: 0, width: outH, height: outW)
        Self.configureRotateDraw(ctx: ctx, quarter: turns, outW: outW, outH: outH)
        ctx.draw(cgImage, in: drawRect)
        return (bytes, outW, outH, bytesPerRow)
    }

    /// Set up `ctx`'s CTM so that the subsequent `ctx.draw(image, in: drawRect)` rotates the source by
    /// `quarter` CLOCKWISE turns and (with the matching draw rect) fills the upright output. One
    /// hardware draw — no per-pixel loop. Proven end-to-end against REAL `preferredTransform` video by
    /// `test_realTransform_identity_topStaysTop` (0°) and `test_realTransform_portrait90_...` (90°).
    ///
    /// Geometry: the destination CGContext is Y-UP and a top-first VT CGImage drawn at the natural
    /// rect lands upright for `turns == 0`. Each non-zero case rotates that upright result about the
    /// output so the raw TOP edge ends up where the displayed video expects it (90°CW → right,
    /// 180° → bottom, 270°CW → left). Rotation signs/translates were pinned empirically by the tests.
    static func configureRotateDraw(ctx: CGContext, quarter: Int, outW: Int, outH: Int) {
        let turns = ((quarter % 4) + 4) % 4
        let ow = Double(outW), oh = Double(outH)
        // Baseline: for `turns == 0` a top-first VT CGImage drawn at the natural rect into this Y-up
        // context lands UPRIGHT (verified by test_realTransform_identity_topStaysTop). We rotate that
        // upright result about the output centre by the visual quarter-turn. Composition is in reverse
        // statement order, so: move origin→centre, rotate, move centre→origin (in PRE-rotation extent).
        // The pre-rotation extent for odd turns is (oh, ow) — i.e. the source/oriented rect we draw.
        switch turns {
        case 0:
            break
        case 1: // 90° clockwise (iPhone portrait): raw top → display RIGHT.
            ctx.translateBy(x: 0, y: oh)
            ctx.rotate(by: -.pi / 2)
        case 2: // 180°.
            ctx.translateBy(x: ow, y: oh)
            ctx.rotate(by: .pi)
        default: // 270° clockwise (90° CCW): raw top → display LEFT.
            ctx.translateBy(x: ow, y: 0)
            ctx.rotate(by: .pi / 2)
        }
        // After the rotation the local axes are in PRE-rotation (oriented) space. The draw rect we use
        // is (orientedW, orientedH); for odd turns oriented == (oh, ow) so the draw fills the rotated
        // box exactly. No extra scale is needed when out == oriented (no downsample); when downsampling
        // the draw rect is still oriented-sized and CoreGraphics scales it into the rotated box.
    }

    // MARK: - Orientation (explicit pixel rotation — mirrors TVECore VideoPresentationInfo mappings)

    /// Number of 90° CLOCKWISE quarter-turns the `preferredTransform` represents, mapping raw track
    /// pixels → upright display. Matches the four cases AVFoundation emits (and the documented UV
    /// mappings in TVECore `VideoPresentationInfo`):
    ///   identity                       → 0
    ///   [a:0 b:1 c:-1 d:0 tx:h ty:0]   → 1  (90° CW, iPhone portrait)
    ///   [a:-1 b:0 c:0 d:-1 tx:w ty:h]  → 2  (180°)
    ///   [a:0 b:-1 c:1 d:0 tx:0 ty:w]   → 3  (90° CCW)
    static func quarterTurns(for t: CGAffineTransform) -> Int {
        // Use the rotation of the +x basis vector (a, b). Sign of b distinguishes CW vs CCW.
        let a = t.a, b = t.b
        let eps = 0.01
        if abs(a - 1) < eps && abs(b) < eps { return 0 }       // 0°
        if abs(a) < eps && abs(b - 1) < eps { return 1 }       // 90° CW
        if abs(a + 1) < eps && abs(b) < eps { return 2 }       // 180°
        if abs(a) < eps && abs(b + 1) < eps { return 3 }       // 90° CCW
        return 0 // unknown → treat as upright (never mirror/guess)
    }

    // MARK: - TEST-ONLY reference oracle (NOT used by production `makePixelInput`)
    //
    // `rotateBGRA` is the slow, obviously-correct reference rotation kept SOLELY so
    // `NextVideoFrameResolverTests` can independently pin the quarter-turn mapping that the fast
    // single-draw production path (`configureRotateDraw`) must match. It is not called by the shipping
    // resolver. Keep it in sync with the documented quarter-turn mapping.

    /// TEST ORACLE. Rotate a top-first BGRA buffer by N clockwise quarter-turns. Returns the rotated
    /// buffer + dimensions (odd turns swap W/H). Pure index remap — no flips, no interpolation.
    static func rotateBGRA(src: [UInt8], width w: Int, height h: Int, quarterTurnsClockwise q: Int)
        -> (bytes: [UInt8], width: Int, height: Int) {
        let turns = ((q % 4) + 4) % 4
        if turns == 0 { return (src, w, h) }
        let srcBPR = w * 4
        let (dw, dh) = (turns % 2 == 0) ? (w, h) : (h, w)
        let dstBPR = dw * 4
        var dst = [UInt8](repeating: 0, count: dstBPR * dh)
        src.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                guard let sb = s.baseAddress, let db = d.baseAddress else { return }
                for y in 0..<h {
                    for x in 0..<w {
                        // Destination coords for a CW rotation of a top-first image.
                        let (dx, dy): (Int, Int)
                        switch turns {
                        case 1: dx = h - 1 - y; dy = x          // 90° CW
                        case 2: dx = w - 1 - x; dy = h - 1 - y  // 180°
                        default: dx = y; dy = w - 1 - x          // 270° CW (== 90° CCW)
                        }
                        let sOff = y * srcBPR + x * 4
                        let dOff = dy * dstBPR + dx * 4
                        (db + dOff).update(from: sb + sOff, count: 4)
                    }
                }
            }
        }
        return (dst, dw, dh)
    }
}

/// Canonical scene-local-time → video-time mapping, kept in the Next-bridge module (no TVECore
/// import) but DEFINED to be byte-identical to `VideoTimelineTimeMapper.targetVideoTime`:
///   tVideo = winStart + max(0, tScene),  clamp [winStart, winEnd - 1/600].
/// where `tScene == (sceneFrame - blockStart) / fps` (the frame-based form the production mapper
/// uses) == the canonical evaluator's `ScenePlaybackTime` seconds for a block that fills its scene.
/// The 1/600 epsilon matches `VideoWindowValidator.epsilon`. `NextVideoTimeMappingTests` pins both
/// the epsilon and the equivalence of the two forms against the production mapper.
enum NextVideoTimeMapping {
    /// MUST equal `VideoWindowValidator.epsilon` (1/600). Pinned by `NextVideoTimeMappingTests`.
    static let epsilon: Double = 1.0 / 600.0

    /// Scene-local seconds → clamped target video time.
    static func targetVideoTime(scenePlaybackSeconds: Double, winStart: Double, winEnd: Double) -> Double {
        let tBlock = max(0.0, scenePlaybackSeconds)
        let tVideo = winStart + tBlock
        return min(max(tVideo, winStart), winEnd - epsilon)
    }

    /// Frame-based form (production mapper's exact signature) — kept for parity testing. Equivalent
    /// to the seconds form with `scenePlaybackSeconds = (sceneFrame - blockStart) / fps`.
    static func targetVideoTime(
        sceneFrameIndex: Int, blockStartFrame: Int, sceneFPS: Double, winStart: Double, winEnd: Double
    ) -> Double {
        let tScene = Double(sceneFrameIndex - blockStartFrame) / sceneFPS
        return targetVideoTime(scenePlaybackSeconds: tScene, winStart: winStart, winEnd: winEnd)
    }
}
#endif
