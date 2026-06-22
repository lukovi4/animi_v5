#if DEBUG
import XCTest
import AVFoundation
import CoreVideo
import Metal
@testable import AnimiApp
import AnimiEngineCore
import AnimiEngineRenderModel
import AnimiEngineMetalRender

/// CP7.8-CORR — tests for the texture-backed video resolver (`NextVideoTextureResolver`): the GPU path
/// that replaced the CPU bake. Covers the corrective fixes:
///   F4 — dynamic sourceID includes the chosen PTS (distinct frames → distinct canonical identity);
///   F1/F2 — same-PTS returns the cached frame; `wouldColdDecode` flags a backward scrub / far advance;
///           `lastCachedFrame` is populated for the bounded soft-skip path.
/// Fixtures are generated at runtime (project convention). Needs a Metal device → skips if unavailable.
final class NextVideoTextureResolverTests: XCTestCase {

    private var tempDir: URL!
    private var device: MTLDevice!
    private var queue: MTLCommandQueue!

    override func setUpWithError() throws {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        device = d
        queue = try XCTUnwrap(d.makeCommandQueue())
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextVideoTextureResolverTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func makeResolver(_ url: URL, ref: String = "cp78-s0-block_01", winEnd: Double = 1.0) -> NextVideoTextureResolver {
        NextVideoTextureResolver(
            blockID: "b", mediaReference: ref,
            window: NextVideoWindow(url: url, winStart: 0, winEnd: winEnd),
            device: device, commandQueue: queue)
    }

    // MARK: - F4: sourceID includes PTS

    func test_F4_sourceID_includesPTS_distinctFramesDistinctIdentity() async throws {
        let url = tempDir.appendingPathComponent("ramp.mp4")
        try await createRampVideo(at: url, frameCount: 30, fps: 30, width: 64, height: 64)
        let r = makeResolver(url)
        let f0 = try r.resolve(scenePlaybackSeconds: 0.0)
        let f1 = try r.resolve(scenePlaybackSeconds: 0.5)   // a clearly later sample
        XCTAssertTrue(f0.descriptor.id.rawValue.hasPrefix("cp78-s0-block_01@"), "sourceID must namespace by ref@pts: \(f0.descriptor.id.rawValue)")
        XCTAssertNotEqual(f0.descriptor.id.rawValue, f1.descriptor.id.rawValue, "different PTS → different canonical identity (Rev-2 §6.2)")
        r.teardown()
    }

    // MARK: - F4 REGRESSION: bridge binds the handle under the descriptor's id (== sourceID with PTS)
    //
    // The red-screen bug: the descriptor id became `ref@pts` (F4) but the runtime binding map stayed keyed
    // by `ref`, so the executor's lookup-by-resourceID missed → `missingTextureBinding` every frame. This
    // test runs the REAL bridge resolve and asserts EVERY dynamic fixture's descriptor.id has a matching
    // texture binding — exactly the invariant that broke. The engine-level GPU test could not catch it
    // (it built graph+bindings by hand with matching ids); only the bridge key-derivation exercises it.

    private func imageSubplan(scene: String, layer: String, ref: String) throws -> SceneSubplan {
        let pt = CanvasScalar.unitsPerPoint
        return SceneSubplan(
            sceneID: try SceneInstanceID(scene), role: .sole,
            visualPlaybackTime: .zero, mediaPlaybackTime: .zero, transitionRelativeTime: nil,
            layers: [ActiveLayer(
                layerID: try LayerID(layer), zIndex: 0, stableOrdinal: 0, localCompositionOrder: 0,
                placement: try Placement(frame: try FixedRect(x: CanvasScalar(rawValue: 0), y: CanvasScalar(rawValue: 0), width: CanvasScalar(rawValue: 100 * pt), height: CanvasScalar(rawValue: 100 * pt)), scale: .one, rotation: .zero),
                mediaPlacement: .identity(fitMode: .contain), content: .image(try ImageReference(ref)),
                animationReference: nil, animationRequest: .holdLast)])
    }

    func test_F4_regression_bridgeBindsHandleUnderDescriptorID() async throws {
        let url = tempDir.appendingPathComponent("ramp.mp4")
        try await createRampVideo(at: url, frameCount: 30, fps: 30, width: 64, height: 64)
        let ref = "cp78-s0-block_01"
        let resolver = makeResolver(url, ref: ref)
        let subplan = try imageSubplan(scene: "cp78-s0", layer: "L1", ref: ref)

        let (dynamicFixtures, bindings, _) = try NextSingleSceneBridge.resolveVideoTexturesSpending(
            subplan: subplan, textureResolvers: [ref: resolver], decodeBudget: .max)

        XCTAssertFalse(dynamicFixtures.isEmpty, "the video ref present in the subplan must resolve to a dynamic fixture")
        // THE invariant: every declared dynamic descriptor's id must have a runtime texture binding.
        for (_, descriptor) in dynamicFixtures {
            XCTAssertNotNil(
                bindings.handle(for: descriptor.id.rawValue),
                "binding map MUST be keyed by descriptor.id (\(descriptor.id.rawValue)); a `ref`-keyed map → missingTextureBinding red screen")
        }
        // And the id carries PTS (F4), so the binding key is NOT the bare ref.
        let onlyDescriptor = dynamicFixtures.values.first!
        XCTAssertNotEqual(onlyDescriptor.id.rawValue, ref, "descriptor id must be ref@pts, not the bare ref")
        XCTAssertNil(bindings.handle(for: ref), "the bare ref must NOT be a binding key (that was the bug)")
        resolver.teardown()
    }

    // MARK: - F1/F2: same-PTS cache + cold-decode classification + last-good

    func test_F1_samePTS_returnsCachedFrame_noRerealize() async throws {
        let url = tempDir.appendingPathComponent("ramp.mp4")
        try await createRampVideo(at: url, frameCount: 30, fps: 30, width: 64, height: 64)
        let r = makeResolver(url)
        _ = try r.resolve(scenePlaybackSeconds: 0.0)
        let before = r.realizeCountForTesting
        // Re-resolve a time that maps to the SAME held sample → cache hit, no new realize.
        _ = try r.resolve(scenePlaybackSeconds: 0.0)
        XCTAssertEqual(r.realizeCountForTesting, before, "same PTS must reuse cached frame (no re-realize)")
        r.teardown()
    }

    func test_F2_wouldColdDecode_trueForBackwardScrub_andLastCachedPopulated() async throws {
        let url = tempDir.appendingPathComponent("ramp.mp4")
        try await createRampVideo(at: url, frameCount: 60, fps: 30, width: 64, height: 64)
        let r = makeResolver(url, winEnd: 2.0)
        // Advance forward to ~1.0s.
        _ = try r.resolve(scenePlaybackSeconds: 1.0)
        XCTAssertNotNil(r.lastCachedFrame, "last-good must be populated after a successful resolve")
        // A BACKWARD scrub to 0.0 cannot be served from the forward reader → cold (rebuild).
        XCTAssertTrue(r.wouldColdDecode(scenePlaybackSeconds: 0.0), "backward scrub must be flagged cold")
        // Re-asking the SAME already-held time is NOT cold.
        XCTAssertFalse(r.wouldColdDecode(scenePlaybackSeconds: 1.0), "same held time must not be cold")
        r.teardown()
    }

    func test_F2_firstResolve_isColdThenCheap() async throws {
        let url = tempDir.appendingPathComponent("ramp.mp4")
        try await createRampVideo(at: url, frameCount: 30, fps: 30, width: 64, height: 64)
        let r = makeResolver(url)
        XCTAssertTrue(r.wouldColdDecode(scenePlaybackSeconds: 0.0), "first resolve (no cache, unprepared) is cold")
        _ = try r.resolve(scenePlaybackSeconds: 0.0)
        XCTAssertFalse(r.wouldColdDecode(scenePlaybackSeconds: 0.0), "after realize, same time is cheap")
        r.teardown()
    }

    // MARK: - Fixture helpers (runtime-generated; mirror NextVideoFrameResolverTests)

    private func createRampVideo(at url: URL, frameCount: Int, fps: Int32, width: Int, height: Int) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ])
        guard writer.canAdd(input) else { throw NSError(domain: "T", code: 1) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "T", code: 2) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            let buffer = try makeRampPixelBuffer(frame: frame, width: width, height: height)
            let pts = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: pts))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? NSError(domain: "T", code: 3) }
    }

    private func makeRampPixelBuffer(frame: Int, width: Int, height: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
        guard status == kCVReturnSuccess, let pb else { throw NSError(domain: "T", code: 4) }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { throw NSError(domain: "T", code: 5) }
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let value = UInt8((frame * 8) % 256)
        for y in 0..<height {
            let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width { let o = x * 4; row[o] = value; row[o+1] = value; row[o+2] = value; row[o+3] = 255 }
        }
        return pb
    }
}
#endif
