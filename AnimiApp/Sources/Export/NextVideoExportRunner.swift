#if DEBUG
import AVFoundation
import CoreVideo
import Foundation
import Metal
import TVECore
import AnimiEngineMetalRender

// MARK: - CP6: AnimiEngineNext video export runner (DEBUG only)
//
// Stateless runner that sources exported video frames from AnimiEngineNext instead of the production
// TVECore export path. It reuses the EXISTING export writer (`ExportWriterPipeline`) and session
// lifecycle (`ExportSession` — cancel/cleanup/progress/finish) verbatim; audio stays the old path
// (a pre-built `BuiltAudioPipeline` is passed straight into the writer's audio input).
//
// CP7.6a — GPU-direct: each output frame is rendered by AnimiEngineNext DIRECTLY into a
// `CVPixelBuffer`-backed `MTLTexture` (via a `CVMetalTextureCache` on the engine's device), with NO
// CPU readback and NO row-by-row `memcpy`. The engine's `render(_:into:)` with `AlphaMode.opaqueBlack`
// composites premultiplied-over-transparent onto opaque black (keep B/G/R, force A = 255) entirely on
// the GPU — the GPU equivalent of the previous CPU `compositeOpaque`.
//
// Frame source: `NextSingleSceneBridge.renderFrame(into:alphaMode:)` /
// `NextTimelineBridge.renderFrame(into:alphaMode:)`. The video-slots coordinator is still unused
// (photo-only). The pure `compositeOpaque` core is retained as a test oracle, not on the hot path.
internal enum NextVideoExportRunner {

    // MARK: - Frame source

    /// The prepared Next context to render from, plus (timeline) the compressed→nominal mapper.
    enum Source {
        case single(NextPreparedContext)
        case timeline(NextTimelinePreparedContext, mapper: TimelinePlayheadMapper)
    }

    // MARK: - Run

    /// Drives the full export. Called on a background queue (like the TVECore runners).
    /// - Parameters:
    ///   - source: Next render source (single-scene or timeline).
    ///   - sessionBox: shared `MetalRenderSession` holder (kept alive for the export).
    ///   - settings: output URL / size / fps / bitrate / GOP (clearColor unused — Next composites to opaque).
    ///   - audioPipeline: pre-built OLD-path audio composition (nil = no audio). Unchanged.
    ///   - totalFrames: number of frames to emit (single: durationFrames; timeline: compressed total).
    ///   - session: shared `ExportSession` owning lifecycle/cancel/cleanup/completion.
    static func run(
        source: Source,
        sessionBox: NextSessionBox,
        settings: NextExportVideoSettings,
        audioPipeline: BuiltAudioPipeline?,
        totalFrames: Int,
        maxFramesInFlight: Int,
        session: ExportSession,
        progress: @escaping (Double) -> Void
    ) {
        // Keep the render session alive for the whole export.
        _ = sessionBox

        if session.completeIfCancelled() { return }

        try? FileManager.default.removeItem(at: settings.outputURL)

        // 1. Writer pipeline (audio unchanged — straight from the pre-built composition).
        let pipeline: ExportWriterPipeline
        do {
            pipeline = try ExportWriterPipeline(
                outputURL: settings.outputURL,
                video: .init(sizePx: settings.sizePx, fps: settings.fps,
                             bitrate: settings.bitrate, gopSeconds: settings.gopSeconds),
                audio: audioPipeline.map { .init(composition: $0.composition, audioMix: $0.audioMix) }
            )
            session.attachPipeline(pipeline)
            if session.completeIfCancelled() { return }
            try pipeline.startWriting()
        } catch {
            session.complete(with: .failure(error))
            return
        }
        if session.completeIfCancelled() { return }

        session.setCleanup(onSuccess: {}, onFailure: {}, onCancel: {})
        if session.completeIfCancelled() { return }

        // CP7.6a: one CVMetalTextureCache on the ENGINE's device, so each pooled CVPixelBuffer can be
        // wrapped as a .bgra8Unorm MTLTexture the engine renders straight into (no readback).
        var textureCacheOpt: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(
            kCFAllocatorDefault, nil, sessionBox.metalDevice, nil, &textureCacheOpt)
        guard cacheStatus == kCVReturnSuccess, let textureCache = textureCacheOpt else {
            session.complete(with: .failure(VideoExportError.renderError(
                NextBridgeError.engine("CVMetalTextureCacheCreate failed: \(cacheStatus)"))))
            return
        }

        session.transitionToRendering()

        // 2. Frame loop. Synchronous render + CPU byte copy, gated by the same semaphore/group pattern.
        let semaphore = DispatchSemaphore(value: max(1, maxFramesInFlight))
        let videoGroup = DispatchGroup()

        guard totalFrames > 0 else {
            session.complete(with: .failure(VideoExportError.renderError(NextBridgeError.engine("totalFrames=0"))))
            return
        }

        for frameIndex in 0..<totalFrames {
            if session.shouldStop { break }
            semaphore.wait()
            videoGroup.enter()

            autoreleasepool {
                guard let pool = pipeline.pixelBufferPool else {
                    pipeline.setError(VideoExportError.noPixelBufferPool)
                    videoGroup.leave(); semaphore.signal(); return
                }
                var pixelBufferOpt: CVPixelBuffer?
                let pbStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBufferOpt)
                guard pbStatus == kCVReturnSuccess, let pixelBuffer = pixelBufferOpt else {
                    pipeline.setError(VideoExportError.failedToCreatePixelBuffer(pbStatus))
                    videoGroup.leave(); semaphore.signal(); return
                }

                // Dimensions must match the encoder's pixel buffer (no downscale in CP6/CP7.6a).
                let pbWidth = CVPixelBufferGetWidth(pixelBuffer)
                let pbHeight = CVPixelBufferGetHeight(pixelBuffer)
                guard pbWidth == settings.sizePx.width, pbHeight == settings.sizePx.height else {
                    pipeline.setError(VideoExportError.renderError(NextBridgeError.engine(
                        "pixel buffer \(pbWidth)x\(pbHeight) != export \(settings.sizePx.width)x\(settings.sizePx.height)")))
                    videoGroup.leave(); semaphore.signal(); return
                }

                // CP7.6a: wrap the pooled CVPixelBuffer as a .bgra8Unorm MTLTexture and render the Next
                // frame straight into it (opaqueBlack), all on the GPU — no readback, no copyOpaque.
                var cvTexOpt: CVMetalTexture?
                let texStatus = CVMetalTextureCacheCreateTextureFromImage(
                    kCFAllocatorDefault, textureCache, pixelBuffer, nil,
                    .bgra8Unorm, pbWidth, pbHeight, 0, &cvTexOpt)
                guard texStatus == kCVReturnSuccess, let cvTex = cvTexOpt,
                      let targetTexture = CVMetalTextureGetTexture(cvTex) else {
                    pipeline.setError(VideoExportError.renderError(NextBridgeError.engine(
                        "CVMetalTextureCacheCreateTextureFromImage failed: \(texStatus)")))
                    videoGroup.leave(); semaphore.signal(); return
                }

                do {
                    try renderFrame(source: source, compressedFrameIndex: frameIndex,
                                    into: targetTexture, alphaMode: .opaqueBlack)
                } catch {
                    pipeline.setError(VideoExportError.renderError(error))
                    videoGroup.leave(); semaphore.signal(); return
                }
                // The CVMetalTexture is retained until here; render(into:) committed+waited, so the GPU
                // write to the pixel buffer is complete. Releasing cvTex now is safe.
                _ = cvTex

                guard !session.shouldStop else { videoGroup.leave(); semaphore.signal(); return }

                let pts = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(settings.fps))
                pipeline.enqueueVideoFrame(pixelBuffer, presentationTime: pts) {
                    videoGroup.leave(); semaphore.signal()
                }
            }

            session.emitProgressIfActive(Double(frameIndex + 1) / Double(totalFrames), via: progress)
        }

        videoGroup.wait()

        if session.shouldStop {
            if !session.isCancelled { pipeline.cancel() }
            session.complete(with: .failure(session.terminalError ?? VideoExportError.cancelled))
        } else {
            session.finishWriting()
        }
    }

    // MARK: - Render dispatch

    private static func renderFrame(
        source: Source, compressedFrameIndex: Int,
        into target: MTLTexture, alphaMode: AlphaMode
    ) throws {
        switch source {
        case .single(let ctx):
            // Single-scene: compressed == nominal == project frame (no transitions).
            try NextSingleSceneBridge.renderFrame(
                context: ctx, frameIndex: compressedFrameIndex, into: target, alphaMode: alphaMode)
        case .timeline(let ctx, let mapper):
            // Timeline: PTS/duration use the COMPRESSED index; the Next evaluator wants the NOMINAL
            // project frame, so map here. The mapper owns transition compression exactly like preview.
            let nominal = mapper.nominalFrame(forCompressedFrame: compressedFrameIndex)
            try NextTimelineBridge.renderFrame(
                context: ctx, frameIndex: nominal, into: target, alphaMode: alphaMode)
        }
    }

    // MARK: - Opaque BGRA composite (test oracle)

    /// Pure BGRA opaque-composite core — the CPU reference for `AlphaMode.opaqueBlack`. NOT on the
    /// CP7.6a hot path (the engine now composites opaque on the GPU); retained as the unit-test oracle
    /// (`NextVideoExportRunnerTests`) and the byte-parity reference for the GPU path. Copies
    /// premultiplied B/G/R verbatim (premultiplied = color·alpha over black) and forces the alpha byte
    /// to 255, i.e. composites premultiplied-over-transparent onto opaque black. Respects differing
    /// source/destination strides.
    internal static func compositeOpaque(
        src: UnsafePointer<UInt8>, srcBytesPerRow: Int,
        dst: UnsafeMutablePointer<UInt8>, dstBytesPerRow: Int,
        width: Int, height: Int
    ) {
        for row in 0..<height {
            let srcRow = src + row * srcBytesPerRow
            let dstRow = dst + row * dstBytesPerRow
            var col = 0
            while col < width {
                let p = col * 4
                dstRow[p + 0] = srcRow[p + 0] // B
                dstRow[p + 1] = srcRow[p + 1] // G
                dstRow[p + 2] = srcRow[p + 2] // R
                dstRow[p + 3] = 255           // A → opaque
                col += 1
            }
        }
    }
}

// MARK: - Settings

/// The minimal video encoder settings the Next runner needs (decoupled from `VideoExportSettings` /
/// `TimelineExportSettings`, which carry TVECore-only fields like `clearColor`/`audioPlan`).
internal struct NextExportVideoSettings {
    let outputURL: URL
    let sizePx: (width: Int, height: Int)
    let fps: Int
    let bitrate: Int
    let gopSeconds: Int
}
#endif
