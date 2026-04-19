import XCTest
import Metal
import CoreVideo
import AVFoundation
import UIKit
@testable import AnimiApp
@testable import TVECore

@MainActor
final class VideoExporterSingleSceneOverlayTests: XCTestCase {

    private func makeTextureCache(device: MTLDevice) -> CVMetalTextureCache? {
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        return cache
    }

    private func makePixelBufferAndTexture(
        device: MTLDevice,
        textureCache: CVMetalTextureCache,
        width: Int,
        height: Int
    ) -> (CVPixelBuffer, MTLTexture)? {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pb
        )
        guard status == kCVReturnSuccess, let pb else { return nil }

        var cvTex: CVMetalTexture?
        let texStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pb,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTex
        )
        guard texStatus == kCVReturnSuccess,
              let cvTex,
              let texture = CVMetalTextureGetTexture(cvTex) else { return nil }
        return (pb, texture)
    }

    private func readPixels(from pb: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(pb)!
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let h = CVPixelBufferGetHeight(pb)
        return Array(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: bpr * h))
    }

    private func hasNonBlackInROI(
        _ pixels: [UInt8],
        bytesPerRow: Int,
        cx: Int,
        cy: Int,
        radius: Int
    ) -> Bool {
        for dy in -radius...radius {
            for dx in -radius...radius {
                let py = cy + dy
                let px = cx + dx
                guard py >= 0, px >= 0 else { continue }
                let offset = py * bytesPerRow + px * 4
                guard offset + 3 < pixels.count else { continue }
                if pixels[offset] > 0 || pixels[offset + 1] > 0 || pixels[offset + 2] > 0 {
                    return true
                }
            }
        }
        return false
    }

    private func makeRuntime(
        width: Int = 1080,
        height: Int = 1920,
        fps: Int = 30,
        durationFrames: Int = 90
    ) -> SceneRuntime {
        let canvas = Canvas(width: width, height: height, fps: fps, durationFrames: durationFrames)
        let scene = Scene(
            schemaVersion: "1.0",
            sceneId: "single-scene-export-test",
            canvas: canvas,
            background: nil,
            mediaBlocks: []
        )
        return SceneRuntime(
            scene: scene,
            canvas: canvas,
            blocks: [],
            durationFrames: durationFrames,
            fps: fps
        )
    }

    private func makeSnapshot() -> SceneRenderStateSnapshot {
        SceneRenderStateSnapshot(
            resolvedTransforms: [:],
            variantOverrides: [:],
            userMediaPresent: [:],
            layerToggleState: [:]
        )
    }

    private func makeBaseTimeline(durationUs: TimeUs = 3_000_000) -> CanonicalTimeline {
        var timeline = CanonicalTimeline.empty()
        let scenePayloadId = UUID()
        timeline.payloads[scenePayloadId] = .scene(ScenePayload(sceneTypeId: "scene_0"))
        timeline.tracks[0].items.append(
            TimelineItem(payloadId: scenePayloadId, kind: .scene, startUs: nil, durationUs: durationUs)
        )
        return timeline
    }

    private func makeTextTimeline(durationUs: TimeUs = 3_000_000) -> CanonicalTimeline {
        var timeline = makeBaseTimeline(durationUs: durationUs)
        let textPayloadId = UUID()
        timeline.payloads[textPayloadId] = .text(TextPayload(
            text: "EXPORT",
            fontFamily: nil,
            fontSize: 72,
            colorHex: "#FFFFFF",
            centerX: 0.5,
            centerY: 0.5
        ))
        let item = TimelineItem(payloadId: textPayloadId, kind: .text, startUs: 0, durationUs: durationUs)
        timeline.tracks.append(Track(kind: .overlay, items: [item]))
        return timeline
    }

    private func makeStickerTimeline(durationUs: TimeUs = 3_000_000, stickerId: String = "test-sticker") -> CanonicalTimeline {
        var timeline = makeBaseTimeline(durationUs: durationUs)
        let stickerPayloadId = UUID()
        timeline.payloads[stickerPayloadId] = .sticker(StickerPayload(stickerId: stickerId, centerX: 0.5, centerY: 0.5))
        let item = TimelineItem(payloadId: stickerPayloadId, kind: .sticker, startUs: 0, durationUs: durationUs)
        timeline.tracks.append(Track(kind: .overlay, items: [item]))
        return timeline
    }

    private func makeStickerFixture(size: Int = 64) throws -> URL {
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("single_scene_sticker_\(UUID().uuidString).png")
        let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let cgImage = context.makeImage()!
        try UIImage(cgImage: cgImage).pngData()!.write(to: fixtureURL)
        return fixtureURL
    }

    func testRenderSingleSceneFrame_textOverlay_pixelsVisibleInCVPixelBuffer() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let textureCache = makeTextureCache(device: device) else {
            throw XCTSkip("Metal device not available")
        }

        let width = 1080
        let height = 1920
        guard let (pb, targetTexture) = makePixelBufferAndTexture(
            device: device,
            textureCache: textureCache,
            width: width,
            height: height
        ) else {
            throw XCTSkip("Failed to create pixel buffer + texture pair")
        }

        let renderer = try MetalRenderer(device: device, colorPixelFormat: .bgra8Unorm)
        let counts = try VideoExporter.renderSingleSceneFrame(
            frameIndex: 0,
            targetTexture: targetTexture,
            runtime: makeRuntime(width: width, height: height),
            snapshot: makeSnapshot(),
            renderer: renderer,
            textureProvider: InMemoryTextureProvider(),
            pathRegistry: PathRegistry(),
            assetSizes: [:],
            backgroundState: nil,
            clearColor: .opaqueBlack,
            overlaySnapshot: OverlayExportSnapshot.build(from: makeTextTimeline(), stickerProvider: nil)
        )

        XCTAssertEqual(counts.textOverlayCount, 1)
        XCTAssertEqual(counts.stickerOverlayCount, 0)

        let pixels = readPixels(from: pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let cx = width / 2
        let cy = height / 2

        XCTAssertTrue(
            hasNonBlackInROI(pixels, bytesPerRow: bpr, cx: cx, cy: cy, radius: 50),
            "Single-scene export frame must contain text overlay pixels at the expected center ROI"
        )
        XCTAssertFalse(
            hasNonBlackInROI(pixels, bytesPerRow: bpr, cx: 10, cy: 10, radius: 5),
            "Control ROI in the corner should stay black"
        )
    }

    func testRenderSingleSceneFrame_stickerOverlay_pixelsVisibleInCVPixelBuffer() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let textureCache = makeTextureCache(device: device) else {
            throw XCTSkip("Metal device not available")
        }

        let width = 1080
        let height = 1920
        guard let (pb, targetTexture) = makePixelBufferAndTexture(
            device: device,
            textureCache: textureCache,
            width: width,
            height: height
        ) else {
            throw XCTSkip("Failed to create pixel buffer + texture pair")
        }

        let fixtureURL = try makeStickerFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let renderer = try MetalRenderer(device: device, colorPixelFormat: .bgra8Unorm)
        let counts = try VideoExporter.renderSingleSceneFrame(
            frameIndex: 0,
            targetTexture: targetTexture,
            runtime: makeRuntime(width: width, height: height),
            snapshot: makeSnapshot(),
            renderer: renderer,
            textureProvider: InMemoryTextureProvider(),
            pathRegistry: PathRegistry(),
            assetSizes: [:],
            backgroundState: nil,
            clearColor: .opaqueBlack,
            overlaySnapshot: OverlayExportSnapshot.build(
                from: makeStickerTimeline(),
                stickerProvider: TestStickerProvider(urlByStickerId: ["test-sticker": fixtureURL])
            )
        )

        XCTAssertEqual(counts.textOverlayCount, 0)
        XCTAssertEqual(counts.stickerOverlayCount, 1)

        let pixels = readPixels(from: pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let cx = width / 2
        let cy = height / 2

        XCTAssertTrue(
            hasNonBlackInROI(pixels, bytesPerRow: bpr, cx: cx, cy: cy, radius: 50),
            "Single-scene export frame must contain sticker overlay pixels at the expected center ROI"
        )
    }

    func testSingleSceneExportPipeline_textOverlay_visibleInOutputFile() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let textureCache = makeTextureCache(device: device) else {
            throw XCTSkip("Metal device not available")
        }

        let width = 540
        let height = 960
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("single_scene_overlay_export_\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let runtime = makeRuntime(width: width, height: height, durationFrames: 30)
        let snapshot = makeSnapshot()
        let timeline = makeTextTimeline(durationUs: 1_000_000)
        let renderer = try MetalRenderer(device: device, colorPixelFormat: .bgra8Unorm)
        let pipeline = try ExportWriterPipeline(
            outputURL: outputURL,
            video: .init(sizePx: (width: width, height: height), fps: 30, bitrate: 2_000_000, gopSeconds: 1),
            audio: nil
        )
        try pipeline.startWriting()

        for frameIndex in 0..<runtime.durationFrames {
            guard let pool = pipeline.pixelBufferPool else {
                XCTFail("No pixel buffer pool")
                return
            }

            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
            guard let pixelBuffer else {
                XCTFail("Failed to create pixel buffer")
                return
            }

            var cvMetalTexture: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                textureCache,
                pixelBuffer,
                nil,
                .bgra8Unorm,
                width,
                height,
                0,
                &cvMetalTexture
            )
            guard let cvMetalTexture,
                  let targetTexture = CVMetalTextureGetTexture(cvMetalTexture) else {
                XCTFail("Failed to create metal texture")
                return
            }

            _ = try VideoExporter.renderSingleSceneFrame(
                frameIndex: frameIndex,
                targetTexture: targetTexture,
                runtime: runtime,
                snapshot: snapshot,
                renderer: renderer,
                textureProvider: InMemoryTextureProvider(),
                pathRegistry: PathRegistry(),
                assetSizes: [:],
                backgroundState: nil,
                clearColor: .opaqueBlack,
                overlaySnapshot: OverlayExportSnapshot.build(from: timeline, stickerProvider: nil)
            )

            let pts = CMTime(value: CMTimeValue(frameIndex), timescale: 30)
            let semaphore = DispatchSemaphore(value: 0)
            pipeline.enqueueVideoFrame(pixelBuffer, presentationTime: pts) {
                semaphore.signal()
            }
            semaphore.wait()
        }

        let finishExpectation = expectation(description: "Writer finishes")
        pipeline.finishWriting { _ in
            finishExpectation.fulfill()
        }
        await fulfillment(of: [finishExpectation], timeout: 5.0)

        let asset = AVURLAsset(url: outputURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw XCTSkip("No video track in output")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        reader.add(output)
        guard reader.startReading() else { throw XCTSkip("Reader failed to start") }
        guard let sample = output.copyNextSampleBuffer(),
              let readbackPB = CMSampleBufferGetImageBuffer(sample) else {
            throw XCTSkip("No frame in output")
        }

        let pixels = readPixels(from: readbackPB)
        let bpr = CVPixelBufferGetBytesPerRow(readbackPB)
        XCTAssertTrue(
            hasNonBlackInROI(pixels, bytesPerRow: bpr, cx: width / 2, cy: height / 2, radius: 50),
            "Single-scene full export pipeline must preserve text overlay pixels in the encoded output file"
        )
    }
}

private final class TestStickerProvider: StickerProviding {
    private let urlByStickerId: [String: URL]

    init(urlByStickerId: [String: URL]) {
        self.urlByStickerId = urlByStickerId
    }

    func loadFromBundle() throws {}

    func descriptor(for stickerId: String) -> StickerDescriptor? {
        StickerDescriptor(id: stickerId, displayName: stickerId, filename: "\(stickerId).png")
    }

    func resourceURL(for stickerId: String) -> URL? {
        urlByStickerId[stickerId]
    }

    var allDescriptors: [StickerDescriptor] {
        urlByStickerId.keys.map { StickerDescriptor(id: $0, displayName: $0, filename: "\($0).png") }
    }

    var count: Int { urlByStickerId.count }
}
