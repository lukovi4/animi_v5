#if DEBUG
import XCTest
import Foundation
import Metal
import AVFoundation
import CoreVideo
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import AnimiApp
@testable import TVECore
import AnimiEngineCore

/// CP7: end-to-end AnimiEngineNext VIDEO export + preview-bridge integration. Builds a real Next
/// prepared context whose media block is a USER VIDEO (resolved per frame to BGRA8), renders frames
/// through the bridge, and drives the actual `NextVideoExportRunner` to produce an MP4 — then reads
/// the MP4 back to assert frame count (no off-by-one) and the opaque (A=255) output contract. Video
/// fixtures are generated at runtime (project convention).
@MainActor
final class NextVideoExportIntegrationTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextVideoExportIT_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func sceneFolderURL(_ id: String) throws -> URL {
        let snapshot = try BundleSceneLibraryLoader().load()
        let scene = try XCTUnwrap(snapshot.scene(byId: id), "bundled scene '\(id)' missing")
        return try XCTUnwrap(scene.folderURL, "bundled scene '\(id)' has no folder URL")
    }

    private func videoInputs(folder: URL, video: URL, winStart: Double, winEnd: Double) -> NextBridgeInputs {
        NextBridgeInputs(
            sceneTypeId: "full_image", sceneFolderURL: folder, variantOverrides: [:],
            blocks: [NextBridgeBlock(
                blockID: "block_01", mediaURL: video,
                placement: NextBridgePlacement(fitModeRaw: "cover", offsetX: 0, offsetY: 0, userScale: 1, rotationDegrees: 0),
                video: NextBridgeVideo(winStart: winStart, winEnd: winEnd))],
            frameIndex: 0)
    }

    // MARK: - 1. Single-scene video render: frames advance, dims match canvas

    func test_singleSceneVideo_rendersAndAdvancesOverTime() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let folder = try sceneFolderURL("full_image")
        let video = tempDir.appendingPathComponent("clip.mp4")
        try runAsync { try await self.createRampVideo(at: video, frameCount: 60, fps: 30, width: 1080, height: 1920) }

        let inputs = videoInputs(folder: folder, video: video, winStart: 0, winEnd: 2.0)
        let sessionBox = try NextSingleSceneBridge.makeSession(device: device)
        let decoded = try NextSingleSceneBridge.decodeMedia(inputs)
        XCTAssertNil(decoded.blocks.first?.photoPixels, "video block must carry a resolver, not photo pixels")
        XCTAssertNotNil(decoded.blocks.first?.videoResolver, "video block must carry a resolver")

        let placementByBlockID = Dictionary(uniqueKeysWithValues: inputs.blocks.map { ($0.blockID, $0.placement) })
        let ctx = try NextSingleSceneBridge.assemble(decoded: decoded, placementByBlockID: placementByBlockID, sessionBox: sessionBox)
        XCTAssertFalse(ctx.videoResolversByReference.isEmpty, "context must hold the video resolver")

        let f0 = try NextSingleSceneBridge.renderFrameBGRA(context: ctx, frameIndex: 0)
        let fLate = try NextSingleSceneBridge.renderFrameBGRA(context: ctx, frameIndex: min(45, ctx.totalFrames - 1))

        // Canvas-sized output.
        XCTAssertEqual(f0.width, 1080)
        XCTAssertEqual(f0.height, 1920)
        // Distinct video content over time (the ramp clip changes per frame).
        XCTAssertNotEqual(Array(f0.bytes.prefix(4096)), Array(fLate.bytes.prefix(4096)),
                          "video frames at distinct times must differ")
    }

    // MARK: - 2. Full export through the runner: frame count + opaque A=255

    func test_singleSceneVideo_exportProducesExpectedFrameCount_andOpaqueAlpha() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let folder = try sceneFolderURL("full_image")
        let video = tempDir.appendingPathComponent("clip.mp4")
        try runAsync { try await self.createRampVideo(at: video, frameCount: 60, fps: 30, width: 1080, height: 1920) }

        let inputs = videoInputs(folder: folder, video: video, winStart: 0, winEnd: 2.0)
        let sessionBox = try NextSingleSceneBridge.makeSession(device: device)
        let decoded = try NextSingleSceneBridge.decodeMedia(inputs)
        let placementByBlockID = Dictionary(uniqueKeysWithValues: inputs.blocks.map { ($0.blockID, $0.placement) })
        let ctx = try NextSingleSceneBridge.assemble(decoded: decoded, placementByBlockID: placementByBlockID, sessionBox: sessionBox)

        let totalFrames = ctx.totalFrames
        XCTAssertGreaterThan(totalFrames, 0)

        let outURL = tempDir.appendingPathComponent("export.mp4")
        let settings = NextExportVideoSettings(
            outputURL: outURL, sizePx: (width: 1080, height: 1920), fps: 30, bitrate: 8_000_000, gopSeconds: 2)

        let done = expectation(description: "export finished")
        var exportResult: Result<URL, Error>?
        let session = ExportSession { result in
            exportResult = result
            done.fulfill()
        }
        // Runner is synchronous + blocking → run off-main like production.
        DispatchQueue.global(qos: .userInitiated).async {
            NextVideoExportRunner.run(
                source: .single(ctx), sessionBox: sessionBox, settings: settings,
                audioPipeline: nil, totalFrames: totalFrames, maxFramesInFlight: 3,
                session: session, progress: { _ in })
        }
        wait(for: [done], timeout: 120)

        switch exportResult {
        case .success(let url):
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "export file exists")
            // Frame count == totalFrames (no off-by-one).
            let asset = AVURLAsset(url: url)
            let count = try countVideoFrames(asset: asset)
            XCTAssertEqual(count, totalFrames, "exported frame count must equal totalFrames")
            // Opaque output: sample the centre of frame 0 → A == 255.
            let alpha = try centerAlpha(asset: asset)
            XCTAssertEqual(alpha, 255, "exported video must be opaque (A=255)")
        case .failure(let e):
            XCTFail("video export failed: \(e)")
        case .none:
            XCTFail("export produced no result")
        }
    }

    // MARK: - 3. Timeline export with a transition where one scene has VIDEO

    func test_timelineVideo_withFade_exportFrameCount_noOffByOne() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let folder = try sceneFolderURL("full_image")
        let video = tempDir.appendingPathComponent("clip.mp4")
        let photo = try tempPhoto("blue", r: 0, g: 0, b: 1)
        try runAsync { try await self.createRampVideo(at: video, frameCount: 60, fps: 30, width: 1080, height: 1920) }

        // Scene A = VIDEO (outgoing), Scene B = photo (incoming), fade boundary.
        let sceneA = NextBridgeTimelineScene(
            scene: videoInputs(folder: folder, video: video, winStart: 0, winEnd: 2.0),
            transitionToNext: NextBridgeTransition(typeRaw: "fade", direction: nil, durationFrames: 14, easingRaw: "linear"))
        let sceneB = NextBridgeTimelineScene(
            scene: NextBridgeInputs(
                sceneTypeId: "full_image", sceneFolderURL: folder, variantOverrides: [:],
                blocks: [NextBridgeBlock(
                    blockID: "block_01", mediaURL: photo,
                    placement: NextBridgePlacement(fitModeRaw: "cover", offsetX: 0, offsetY: 0, userScale: 1, rotationDegrees: 0))],
                frameIndex: 0),
            transitionToNext: nil)
        let inputs = NextBridgeTimelineInputs(scenes: [sceneA, sceneB], nominalFrameIndex: 0, fps: 30)

        let sessionBox = try NextSingleSceneBridge.makeSession(device: device)
        let decoded = try NextTimelineBridge.decodeTimeline(inputs)
        let ctx = try NextTimelineBridge.assembleTimeline(decoded: decoded, inputs: inputs, sessionBox: sessionBox)
        XCTAssertFalse(ctx.videoResolversByReference.isEmpty, "timeline context must hold scene A's video resolver")

        // Mirror the runner's compressed→nominal mapping for total frame count.
        let math = TimelineTransitionMath(
            sceneItems: inputs.scenes.enumerated().map { (i, _) in
                TimelineItem(id: UUID(), payloadId: UUID(), kind: .scene, startUs: nil, durationUs: 2 * 1_000_000)
            },
            boundaryTransitions: [:], fps: 30)
        let mapper = TimelinePlayheadMapper(math: math)
        let compressedTotal = math.compressedDurationFrames

        let outURL = tempDir.appendingPathComponent("export_tl.mp4")
        let settings = NextExportVideoSettings(
            outputURL: outURL, sizePx: (width: 1080, height: 1920), fps: 30, bitrate: 8_000_000, gopSeconds: 2)

        let done = expectation(description: "timeline export finished")
        var exportResult: Result<URL, Error>?
        let session = ExportSession { result in exportResult = result; done.fulfill() }
        DispatchQueue.global(qos: .userInitiated).async {
            NextVideoExportRunner.run(
                source: .timeline(ctx, mapper: mapper), sessionBox: sessionBox, settings: settings,
                audioPipeline: nil, totalFrames: compressedTotal, maxFramesInFlight: 3,
                session: session, progress: { _ in })
        }
        wait(for: [done], timeout: 180)

        switch exportResult {
        case .success(let url):
            let asset = AVURLAsset(url: url)
            let count = try countVideoFrames(asset: asset)
            XCTAssertEqual(count, compressedTotal, "timeline export frame count must equal compressed total (no off-by-one)")
        case .failure(let e):
            XCTFail("timeline video export failed: \(e)")
        case .none:
            XCTFail("timeline export produced no result")
        }
    }

    // MARK: - Helpers

    private func runAsync(_ body: @escaping () async throws -> Void) throws {
        let exp = expectation(description: "async")
        var thrown: Error?
        Task { do { try await body() } catch { thrown = error }; exp.fulfill() }
        wait(for: [exp], timeout: 120)
        if let thrown { throw thrown }
    }

    private func countVideoFrames(asset: AVURLAsset) throws -> Int {
        guard let track = asset.tracks(withMediaType: .video).first else { return 0 }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var n = 0
        while let sb = output.copyNextSampleBuffer() {
            if CMSampleBufferGetImageBuffer(sb) != nil { n += 1 }
        }
        return n
    }

    private func centerAlpha(asset: AVURLAsset) throws -> UInt8 {
        guard let track = asset.tracks(withMediaType: .video).first else { return 0 }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        guard let sb = output.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) else { return 0 }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return 0 }
        let p = base.advanced(by: (h / 2) * bpr + (w / 2) * 4).assumingMemoryBound(to: UInt8.self)
        return p[3] // BGRA → alpha at +3
    }

    private func tempPhoto(_ name: String, w: Int = 64, h: Int = 64, r: CGFloat, g: CGFloat, b: CGFloat) throws -> URL {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let image = try XCTUnwrap(ctx.makeImage())
        let url = tempDir.appendingPathComponent("cp7-\(name).png")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func createRampVideo(at url: URL, frameCount: Int, fps: Int32, width: Int, height: Int) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        guard writer.canAdd(input) else { throw NSError(domain: "NextVideoExportIT", code: 1) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "NextVideoExportIT", code: 2) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
            guard let pb else { throw NSError(domain: "NextVideoExportIT", code: 3) }
            CVPixelBufferLockBaseAddress(pb, [])
            let bpr = CVPixelBufferGetBytesPerRow(pb)
            let base = CVPixelBufferGetBaseAddress(pb)!
            let value = UInt8((frame * 8) % 256)
            for y in 0..<height {
                let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width { let o = x * 4; row[o]=value; row[o+1]=value; row[o+2]=value; row[o+3]=255 }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            XCTAssertTrue(adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? NSError(domain: "NextVideoExportIT", code: 4) }
    }
}
#endif
