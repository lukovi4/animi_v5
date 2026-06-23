#if DEBUG
import XCTest
import Foundation
import AVFoundation
import CoreVideo
import Metal
@testable import AnimiApp

/// CP7.9 Phase 3D.3-CORR2 — REAL pending re-fire regression for the settle path. Unlike the pure-helper
/// tests (`coalesceDidSettle`/`previewMode`), this drives the ACTUAL controller path:
///   requestTexture/requestTimelineTexture → inFlight → pending slot → completion → pending re-fire →
///   previewVideoStrategy(mode: .settled)
/// and asserts `lastResolvedPreviewModeForTesting == .settled` for the re-fired request. Uses a real
/// runtime-generated video fixture (project convention). No TEMP probes; the only seam is the existing
/// production-neutral DEBUG `lastResolvedPreviewModeForTesting`.
@MainActor
final class NextPreviewControllerSettleTests: XCTestCase {

    private var tempDir: URL!
    private var device: MTLDevice!

    override func setUpWithError() throws {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        device = d
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextPreviewControllerSettleTests_\(UUID().uuidString)", isDirectory: true)
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

    private func videoInputs(folder: URL, video: URL, frameIndex: Int) -> NextBridgeInputs {
        NextBridgeInputs(
            sceneTypeId: "full_image", sceneFolderURL: folder, variantOverrides: [:],
            blocks: [NextBridgeBlock(
                blockID: "block_01", mediaURL: video,
                placement: NextBridgePlacement(fitModeRaw: "cover", offsetX: 0, offsetY: 0, userScale: 1, rotationDegrees: 0),
                video: NextBridgeVideo(winStart: 0, winEnd: 2.0))],
            frameIndex: frameIndex)
    }

    /// Poll the main-actor controller seam until `predicate` holds or timeout (drives the runloop so async
    /// render completions / pending re-fires can land). Returns true if satisfied.
    private func waitUntil(timeout: TimeInterval = 8.0, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return predicate()
    }

    // MARK: - Single-scene: real pending re-fire carries .settled

    func test_singleScene_pendingRefire_resolvesSettledMode() throws {
        let folder = try sceneFolderURL("full_image")
        let video = tempDir.appendingPathComponent("clip.mp4")
        try runAsync { try await self.createRampVideo(at: video, frameCount: 60, fps: 30, width: 192, height: 192) }

        let controller = NextPreviewController(device: device)

        // Request #1: starts the GPU-direct render → controller.inFlight becomes true synchronously.
        controller.requestTexture(videoInputs(folder: folder, video: video, frameIndex: 0), isPlaying: false, didSettle: false) { _ in }
        // Request #2 (WHILE inFlight): a SETTLE → coalesced into the pending slot (not run yet).
        controller.requestTexture(videoInputs(folder: folder, video: video, frameIndex: 5), isPlaying: false, didSettle: true) { _ in }
        // Request #3 (still inFlight): a later NON-settle must NOT drop the sticky pending settle.
        controller.requestTexture(videoInputs(folder: folder, video: video, frameIndex: 6), isPlaying: false, didSettle: false) { _ in }

        // When #1 finishes, the pending slot re-fires with sticky didSettle=true → previewVideoStrategy
        // resolves `.settled` for that re-fired render.
        let reached = waitUntil { controller.lastResolvedPreviewModeForTesting == .settled }
        XCTAssertTrue(reached,
                      "the real pending re-fire must resolve .settled (got \(String(describing: controller.lastResolvedPreviewModeForTesting)))")
    }

    // MARK: - Timeline: separate pending tuple also carries .settled

    func test_timeline_pendingRefire_resolvesSettledMode() throws {
        // A timeline needs ≥2 scenes (a single-scene timeline routes to the single-scene path). Two video
        // scenes + a fade exercise the SEPARATE timeline pending tuple.
        let folder = try sceneFolderURL("full_image")
        let videoA = tempDir.appendingPathComponent("tlA.mp4")
        let videoB = tempDir.appendingPathComponent("tlB.mp4")
        try runAsync {
            try await self.createRampVideo(at: videoA, frameCount: 60, fps: 30, width: 192, height: 192)
            try await self.createRampVideo(at: videoB, frameCount: 60, fps: 30, width: 192, height: 192)
        }

        func scene(_ frame: Int) -> NextBridgeTimelineInputs {
            let a = NextBridgeTimelineScene(
                scene: videoInputs(folder: folder, video: videoA, frameIndex: 0),
                transitionToNext: NextBridgeTransition(typeRaw: "fade", direction: nil, durationFrames: 14, easingRaw: "linear"))
            let b = NextBridgeTimelineScene(
                scene: videoInputs(folder: folder, video: videoB, frameIndex: 0), transitionToNext: nil)
            return NextBridgeTimelineInputs(scenes: [a, b], nominalFrameIndex: frame, fps: 30)
        }

        let controller = NextPreviewController(device: device)
        var outcomes: [String] = []
        func tag(_ o: NextPreviewController.TextureOutcome) -> String {
            switch o { case .texture: return "texture"; case .skipped: return "skipped"; case .failure(let e): return "failure(\(e))" }
        }
        controller.requestTimelineTexture(scene(0), isPlaying: false, didSettle: false) { outcomes.append("1:" + tag($0)) }   // inFlight=true
        controller.requestTimelineTexture(scene(5), isPlaying: false, didSettle: true) { outcomes.append("2:" + tag($0)) }    // pending settle
        controller.requestTimelineTexture(scene(6), isPlaying: false, didSettle: false) { outcomes.append("3:" + tag($0)) }   // sticky check

        let reached = waitUntil { controller.lastResolvedPreviewModeForTesting == .settled }
        XCTAssertTrue(reached,
                      "the timeline pending re-fire must resolve .settled (got \(String(describing: controller.lastResolvedPreviewModeForTesting))) outcomes=\(outcomes)")
    }

    // MARK: - Helpers

    private func runAsync(_ body: @escaping () async throws -> Void) throws {
        let exp = expectation(description: "async")
        var thrown: Error?
        Task { do { try await body() } catch { thrown = error }; exp.fulfill() }
        wait(for: [exp], timeout: 60)
        if let thrown { throw thrown }
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
        guard writer.canAdd(input) else { throw NSError(domain: "SettleIT", code: 1) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "SettleIT", code: 2) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
            guard let pb else { throw NSError(domain: "SettleIT", code: 3) }
            CVPixelBufferLockBaseAddress(pb, [])
            let bpr = CVPixelBufferGetBytesPerRow(pb)
            let base = CVPixelBufferGetBaseAddress(pb)!
            let value = UInt8((frame * 8) % 256)
            for y in 0..<height {
                let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width { let o = x * 4; row[o]=value; row[o+1]=value; row[o+2]=value; row[o+3]=255 }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            _ = adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? NSError(domain: "SettleIT", code: 4) }
    }
}
#endif
