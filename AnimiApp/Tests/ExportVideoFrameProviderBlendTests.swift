import AVFoundation
import CoreVideo
import Metal
import XCTest
@testable import AnimiApp
@testable import TVECore

final class ExportVideoFrameProviderBlendTests: XCTestCase {

    private let dummyURL = URL(fileURLWithPath: "/dev/null")

    private func makeSelection(
        trimStart: Double = 0,
        trimEnd: Double = 10
    ) -> VideoSelection {
        VideoSelection(url: dummyURL, trimStart: trimStart, trimEnd: trimEnd)
    }

    // MARK: - Config Default Policy

    func test_config_defaultPolicy_isBlend() {
        let config = ExportVideoFrameProvider.Config(selection: makeSelection())
        XCTAssertEqual(config.resamplingPolicy, .blend)
    }

    func test_config_explicitNearest() {
        let config = ExportVideoFrameProvider.Config(
            selection: makeSelection(),
            resamplingPolicy: .nearest
        )
        XCTAssertEqual(config.resamplingPolicy, .nearest)
    }

    func test_config_explicitBlend() {
        let config = ExportVideoFrameProvider.Config(
            selection: makeSelection(),
            resamplingPolicy: .blend
        )
        XCTAssertEqual(config.resamplingPolicy, .blend)
    }

    // MARK: - Export-Owned Texture Contract

    func test_providerReturnsExportOwnedTexture_notCoreVideoBackedTexture() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal not available")
        }

        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            XCTFail("Failed to create CVMetalTextureCache: \(status)")
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-provider-owned-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await createColorRampVideo(at: url, frameCount: 4, fps: 24)

        let provider = ExportVideoFrameProvider(
            device: device,
            textureCache: cache,
            commandQueue: commandQueue,
            config: .init(
                selection: VideoSelection(url: url, trimStart: 0, trimEnd: 4.0 / 24.0),
                resamplingPolicy: .nearest
            )
        )
        try provider.prepare()
        defer { provider.finish() }

        guard let texture = provider.texture(forTargetVideoTime: 0) else {
            XCTFail("Provider did not return decoded texture")
            return
        }

        XCTAssertEqual(texture.storageMode, .private,
                       "Export provider must copy decoded frames into owned Metal storage before caching")
        XCTAssertNil(texture.iosurface,
                     "Export provider must not cache CoreVideo-backed textures across render frames")
    }

    // MARK: - ResamplingDecision: .nearest policy

    func test_nearest_alwaysReturnsPrev() {
        let decision = ResamplingDecision.decide(
            policy: .nearest,
            targetSeconds: 0.5,
            lastPTSSeconds: 0.0,
            nextPTSSeconds: 1.0
        )
        XCTAssertEqual(decision, .usePrev)
    }

    // MARK: - ResamplingDecision: exact-prev branch

    func test_blend_exactPrev_withinEpsilon() {
        let epsilon = 1.0 / 600.0
        let decision = ResamplingDecision.decide(
            policy: .blend,
            targetSeconds: 1.0 + epsilon * 0.5,
            lastPTSSeconds: 1.0,
            nextPTSSeconds: 1.0 + 1.0 / 24.0
        )
        XCTAssertEqual(decision, .usePrev)
    }

    func test_blend_exactPrev_atExactTime() {
        let decision = ResamplingDecision.decide(
            policy: .blend,
            targetSeconds: 2.0,
            lastPTSSeconds: 2.0,
            nextPTSSeconds: 2.0 + 1.0 / 24.0
        )
        XCTAssertEqual(decision, .usePrev)
    }

    // MARK: - ResamplingDecision: exact-next branch

    func test_blend_exactNext_withinEpsilon() {
        let epsilon = 1.0 / 600.0
        let nextPTS = 1.0 + 1.0 / 24.0
        let decision = ResamplingDecision.decide(
            policy: .blend,
            targetSeconds: nextPTS - epsilon * 0.5,
            lastPTSSeconds: 1.0,
            nextPTSSeconds: nextPTS
        )
        XCTAssertEqual(decision, .useNext)
    }

    // MARK: - ResamplingDecision: blend branch (upsampling 24→30)

    func test_blend_midpoint_returnsBlendHalf() {
        // 24fps source: samples at 0.0 and 1/24 ≈ 0.04167
        // 30fps output: target at 1/30 ≈ 0.03333 (between samples)
        let lastPTS = 0.0
        let nextPTS = 1.0 / 24.0
        let target = 1.0 / 30.0

        let decision = ResamplingDecision.decide(
            policy: .blend,
            targetSeconds: target,
            lastPTSSeconds: lastPTS,
            nextPTSSeconds: nextPTS
        )

        // alpha = (1/30 - 0) / (1/24 - 0) = 24/30 = 0.8
        let expectedAlpha = Float(target / nextPTS)
        if case .blend(let alpha) = decision {
            XCTAssertEqual(alpha, expectedAlpha, accuracy: 0.001)
        } else {
            XCTFail("Expected .blend, got \(decision)")
        }
    }

    func test_blend_quarterPoint_returnsCorrectAlpha() {
        let lastPTS = 1.0
        let nextPTS = 2.0
        let target = 1.25

        let decision = ResamplingDecision.decide(
            policy: .blend,
            targetSeconds: target,
            lastPTSSeconds: lastPTS,
            nextPTSSeconds: nextPTS
        )

        if case .blend(let alpha) = decision {
            XCTAssertEqual(alpha, 0.25, accuracy: 0.001)
        } else {
            XCTFail("Expected .blend, got \(decision)")
        }
    }

    // MARK: - ResamplingDecision: fallback cases

    func test_blend_noLastPTS_returnsPrev() {
        let decision = ResamplingDecision.decide(
            policy: .blend,
            targetSeconds: 0.5,
            lastPTSSeconds: nil,
            nextPTSSeconds: 1.0
        )
        XCTAssertEqual(decision, .usePrev)
    }

    func test_blend_noNextPTS_returnsPrev() {
        let decision = ResamplingDecision.decide(
            policy: .blend,
            targetSeconds: 0.5,
            lastPTSSeconds: 0.0,
            nextPTSSeconds: nil
        )
        XCTAssertEqual(decision, .usePrev)
    }

    func test_blend_zeroSpan_returnsPrev() {
        // lastPTS == nextPTS (degenerate case)
        let decision = ResamplingDecision.decide(
            policy: .blend,
            targetSeconds: 1.0,
            lastPTSSeconds: 1.0,
            nextPTSSeconds: 1.0
        )
        // Both are within epsilon of target → exact prev wins
        XCTAssertEqual(decision, .usePrev)
    }

    // MARK: - ResamplingDecision: 60→30 downsampling scenario

    func test_60to30_exactHit_noBlend() {
        // 60fps source, 30fps output: every output frame matches a source sample exactly
        let sourceFPS = 60.0
        let outputFPS = 30.0

        for i in 0..<30 {
            let outputTime = Double(i) / outputFPS
            let lastPTS = Double(i * 2) / sourceFPS  // every other source frame
            let nextPTS = Double(i * 2 + 1) / sourceFPS

            let decision = ResamplingDecision.decide(
                policy: .blend,
                targetSeconds: outputTime,
                lastPTSSeconds: lastPTS,
                nextPTSSeconds: nextPTS
            )

            // outputTime == lastPTS exactly (i/30 == 2i/60), so should be exact prev
            XCTAssertEqual(decision, .usePrev, "Frame \(i): expected .usePrev for 60→30 exact hit")
        }
    }

    // MARK: - Helpers

    private func createColorRampVideo(at url: URL, frameCount: Int, fps: Int32) async throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 16,
                AVVideoHeightKey: 16,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 1_000_000,
                    AVVideoExpectedSourceFrameRateKey: Int(fps)
                ]
            ]
        )
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 16,
                kCVPixelBufferHeightKey as String: 16,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )

        guard writer.canAdd(input) else {
            throw NSError(domain: "ExportVideoFrameProviderBlendTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot add video input"])
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "ExportVideoFrameProviderBlendTests", code: 2)
        }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                await Task.yield()
            }
            let buffer = try makePixelBuffer(frame: frame)
            let pts = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: pts),
                          "Failed to append test video frame \(frame)")
        }

        input.markAsFinished()
        await writer.finishWriting()

        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "ExportVideoFrameProviderBlendTests", code: 3,
                                          userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter failed"])
        }
    }

    private func makePixelBuffer(frame: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            16,
            16,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw NSError(domain: "ExportVideoFrameProviderBlendTests", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create pixel buffer"])
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw NSError(domain: "ExportVideoFrameProviderBlendTests", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Missing pixel buffer base address"])
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let value = UInt8(min(frame * 60, 255))
        for y in 0..<16 {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<16 {
                let offset = x * 4
                row[offset + 0] = value
                row[offset + 1] = UInt8(255 - Int(value))
                row[offset + 2] = UInt8((Int(value) + 80) % 255)
                row[offset + 3] = 255
            }
        }

        return pixelBuffer
    }
}
