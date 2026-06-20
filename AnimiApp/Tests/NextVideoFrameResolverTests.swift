#if DEBUG
import XCTest
import AVFoundation
import CoreVideo
@testable import AnimiApp
import AnimiEngineRenderModel

/// CP7: behavioural tests for the Next bridge's CPU video-frame resolver
/// (`NextVideoBlockResolver`). Proves it produces canonical BGRA8 `ResolvedPixelInput` at the
/// requested scene-local time, advances frames over time, handles backward scrub via reader rebuild,
/// and fails closed (typed error) on missing / corrupt media. Fixtures are generated at runtime
/// (the project's convention — no static .mov/.mp4 checked in).
final class NextVideoFrameResolverTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextVideoResolverTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: - Valid video → BGRA8 with expected dimensions

    func test_validVideo_returnsBGRA8_downsampledToMaxPixel() async throws {
        let url = tempDir.appendingPathComponent("ramp.mp4")
        try await createRampVideo(at: url, frameCount: 30, fps: 30, width: 128, height: 64)

        let resolver = NextVideoBlockResolver(
            blockID: "b", mediaReference: "ref-b",
            window: NextVideoWindow(url: url, winStart: 0, winEnd: 1.0), maxPixelSize: 64)
        let pixels = try resolver.resolve(scenePlaybackSeconds: 0)

        XCTAssertEqual(pixels.dimensions.format, .bgra8)
        XCTAssertEqual(pixels.dimensions.orientation, .up)
        // 128x64 oriented, capped to long-edge 64 → 64x32.
        XCTAssertEqual(pixels.dimensions.width, 64)
        XCTAssertEqual(pixels.dimensions.height, 32)
        XCTAssertEqual(pixels.dimensions.bytesPerRow, 64 * 4)
        XCTAssertEqual(pixels.bytes.count, pixels.dimensions.requiredByteCount)
        resolver.teardown()
    }

    func test_pixelInputID_isMediaReference() async throws {
        let url = tempDir.appendingPathComponent("ramp.mp4")
        try await createRampVideo(at: url, frameCount: 10, fps: 30, width: 64, height: 64)
        let resolver = NextVideoBlockResolver(
            blockID: "b", mediaReference: "cp7-s0-block_01",
            window: NextVideoWindow(url: url, winStart: 0, winEnd: 0.3), maxPixelSize: 64)
        let pixels = try resolver.resolve(scenePlaybackSeconds: 0)
        XCTAssertEqual(pixels.id.rawValue, "cp7-s0-block_01")
        resolver.teardown()
    }

    // MARK: - Distinct frames over time (advances forward)

    func test_advancesOverTime_distinctFrameContent() async throws {
        let url = tempDir.appendingPathComponent("ramp.mp4")
        // 30 frames over 1s, each frame a distinct grey ramp.
        try await createRampVideo(at: url, frameCount: 30, fps: 30, width: 64, height: 64)
        let resolver = NextVideoBlockResolver(
            blockID: "b", mediaReference: "ref",
            window: NextVideoWindow(url: url, winStart: 0, winEnd: 1.0), maxPixelSize: 64)

        let early = try resolver.resolve(scenePlaybackSeconds: 0.0)   // frame 0
        let late = try resolver.resolve(scenePlaybackSeconds: 0.8)    // frame ~24

        XCTAssertNotEqual(early.contentHash, late.contentHash,
                          "frames at distinct times must differ (ramp video advances)")
        resolver.teardown()
    }

    // MARK: - Backward scrub (reader rebuild, no crash, correct content)

    func test_backwardRequest_reseeksAndReturnsFrame() async throws {
        let url = tempDir.appendingPathComponent("ramp.mp4")
        try await createRampVideo(at: url, frameCount: 30, fps: 30, width: 64, height: 64)
        let resolver = NextVideoBlockResolver(
            blockID: "b", mediaReference: "ref",
            window: NextVideoWindow(url: url, winStart: 0, winEnd: 1.0), maxPixelSize: 64)

        let forwardEarly = try resolver.resolve(scenePlaybackSeconds: 0.0)
        _ = try resolver.resolve(scenePlaybackSeconds: 0.8)            // advance forward
        let backEarly = try resolver.resolve(scenePlaybackSeconds: 0.0) // scrub BACK to start

        // After a backward request the reader rebuilds; the start frame content must match the first
        // forward read of the same time (deterministic decode of the same sample).
        XCTAssertEqual(forwardEarly.contentHash, backEarly.contentHash,
                       "backward scrub must reseek and return the same start frame")
        resolver.teardown()
    }

    // MARK: - Hold-last within a window (target between samples reuses the preceding sample)

    func test_holdLast_targetBetweenSamples_usesPrecedingFrame() async throws {
        let url = tempDir.appendingPathComponent("ramp.mp4")
        try await createRampVideo(at: url, frameCount: 30, fps: 30, width: 64, height: 64)
        let resolver = NextVideoBlockResolver(
            blockID: "b", mediaReference: "ref",
            window: NextVideoWindow(url: url, winStart: 0, winEnd: 1.0), maxPixelSize: 64)

        // 0.50s == frame 15 exactly; 0.51s falls between frame 15 (0.5s) and 16 (0.533s) → hold frame 15.
        let onFrame = try resolver.resolve(scenePlaybackSeconds: 0.50)
        resolver.teardown()
        // Fresh resolver to read the in-between time from a clean state.
        let resolver2 = NextVideoBlockResolver(
            blockID: "b", mediaReference: "ref",
            window: NextVideoWindow(url: url, winStart: 0, winEnd: 1.0), maxPixelSize: 64)
        let between = try resolver2.resolve(scenePlaybackSeconds: 0.51)
        XCTAssertEqual(onFrame.contentHash, between.contentHash,
                       "a target between samples must hold the preceding decoded frame")
        resolver2.teardown()
    }

    // MARK: - Trim window respected (winStart offsets which source frame is read)

    func test_trimStart_offsetsSourceFrame() async throws {
        let url = tempDir.appendingPathComponent("ramp.mp4")
        try await createRampVideo(at: url, frameCount: 60, fps: 30, width: 64, height: 64)

        // Untrimmed: scene 0 → video 0 (frame 0).
        let r0 = NextVideoBlockResolver(
            blockID: "b", mediaReference: "ref",
            window: NextVideoWindow(url: url, winStart: 0, winEnd: 2.0), maxPixelSize: 64)
        let untrimmedStart = try r0.resolve(scenePlaybackSeconds: 0)
        r0.teardown()

        // Trimmed winStart=1.0: scene 0 → video 1.0s (frame 30) — different content.
        let r1 = NextVideoBlockResolver(
            blockID: "b", mediaReference: "ref",
            window: NextVideoWindow(url: url, winStart: 1.0, winEnd: 2.0), maxPixelSize: 64)
        let trimmedStart = try r1.resolve(scenePlaybackSeconds: 0)
        r1.teardown()

        XCTAssertNotEqual(untrimmedStart.contentHash, trimmedStart.contentHash,
                          "trimStart must offset which source frame scene-time 0 maps to")
    }

    // MARK: - Orientation: no vertical flip (top stays top)

    func test_orientation_topStaysTop_noVerticalFlip() async throws {
        // Fixture: TOP half white, BOTTOM half black, identity preferredTransform. After resolve the
        // engine consumes `.up` (row 0 = top). Row 0 must be WHITE and the last row BLACK — a vertical
        // flip (the reported bug) would invert this.
        let url = tempDir.appendingPathComponent("split.mp4")
        try await createTopBottomSplitVideo(at: url, frameCount: 6, fps: 30, width: 64, height: 64)
        let resolver = NextVideoBlockResolver(
            blockID: "b", mediaReference: "ref",
            window: NextVideoWindow(url: url, winStart: 0, winEnd: 0.15), maxPixelSize: 64)
        let pixels = try resolver.resolve(scenePlaybackSeconds: 0)
        defer { resolver.teardown() }

        let w = pixels.dimensions.width, h = pixels.dimensions.height
        let bpr = pixels.dimensions.bytesPerRow
        let bytes = [UInt8](pixels.bytes)
        // Sample blue channel (B) of the centre column in the first and last row.
        let topB = Int(bytes[0 * bpr + (w / 2) * 4 + 0])
        let bottomB = Int(bytes[(h - 1) * bpr + (w / 2) * 4 + 0])
        XCTAssertGreaterThan(topB, 180, "row 0 (top) must be the WHITE half — not flipped")
        XCTAssertLessThan(bottomB, 75, "last row (bottom) must be the BLACK half — not flipped")
    }

    private func createTopBottomSplitVideo(at url: URL, frameCount: Int, fps: Int32, width: Int, height: Int) async throws {
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
        guard writer.canAdd(input) else { throw NSError(domain: "NextVideoResolverTests", code: 10) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "NextVideoResolverTests", code: 11) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
            guard let pb else { throw NSError(domain: "NextVideoResolverTests", code: 12) }
            CVPixelBufferLockBaseAddress(pb, [])
            let bpr = CVPixelBufferGetBytesPerRow(pb)
            let base = CVPixelBufferGetBaseAddress(pb)!
            // CVPixelBuffer row 0 == TOP of the displayed frame. White top half, black bottom half.
            for y in 0..<height {
                let v: UInt8 = (y < height / 2) ? 255 : 0
                let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width { let o = x * 4; row[o]=v; row[o+1]=v; row[o+2]=v; row[o+3]=255 }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            XCTAssertTrue(adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? NSError(domain: "NextVideoResolverTests", code: 13) }
    }

    // MARK: - Orientation: quarterTurns derivation + explicit BGRA rotation (the "flipped" fix)

    func test_quarterTurns_matchesAVFoundationTransforms() {
        let w: CGFloat = 1920, h: CGFloat = 1080
        XCTAssertEqual(NextVideoBlockResolver.quarterTurns(for: .identity), 0)
        XCTAssertEqual(NextVideoBlockResolver.quarterTurns(for: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)), 1, "iPhone portrait 90° CW")
        XCTAssertEqual(NextVideoBlockResolver.quarterTurns(for: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)), 2, "180°")
        XCTAssertEqual(NextVideoBlockResolver.quarterTurns(for: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)), 3, "90° CCW")
    }

    /// Build a top-first BGRA buffer: TOP half white, BOTTOM half black.
    private func topWhiteBottomBlack(w: Int, h: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: w * 4 * h)
        for y in 0..<h {
            let v: UInt8 = (y < h / 2) ? 255 : 0
            for x in 0..<w { let o = (y * w + x) * 4; b[o]=v; b[o+1]=v; b[o+2]=v; b[o+3]=255 }
        }
        return b
    }
    private func blue(_ bytes: [UInt8], w: Int, x: Int, y: Int) -> Int { Int(bytes[(y * w + x) * 4 + 0]) }

    func test_rotate0_identity_topStaysWhite() {
        let w = 48, h = 64
        let (out, ow, oh) = NextVideoBlockResolver.rotateBGRA(src: topWhiteBottomBlack(w: w, h: h), width: w, height: h, quarterTurnsClockwise: 0)
        XCTAssertEqual(ow, w); XCTAssertEqual(oh, h)
        XCTAssertGreaterThan(blue(out, w: ow, x: ow/2, y: 0), 180, "identity: top white")
        XCTAssertLessThan(blue(out, w: ow, x: ow/2, y: oh - 1), 75, "identity: bottom black")
    }

    func test_rotate90CW_topGoesRight() {
        // 90° CW of a top-first image: the TOP edge rotates to the RIGHT edge.
        let w = 64, h = 48
        let (out, ow, oh) = NextVideoBlockResolver.rotateBGRA(src: topWhiteBottomBlack(w: w, h: h), width: w, height: h, quarterTurnsClockwise: 1)
        XCTAssertEqual(ow, h, "90°: width = raw height")
        XCTAssertEqual(oh, w, "90°: height = raw width")
        XCTAssertGreaterThan(blue(out, w: ow, x: ow - 1, y: oh/2), 180, "90°CW: white (raw top) on the RIGHT")
        XCTAssertLessThan(blue(out, w: ow, x: 0, y: oh/2), 75, "90°CW: black (raw bottom) on the LEFT")
    }

    func test_rotate180_topGoesBottom() {
        let w = 48, h = 64
        let (out, ow, oh) = NextVideoBlockResolver.rotateBGRA(src: topWhiteBottomBlack(w: w, h: h), width: w, height: h, quarterTurnsClockwise: 2)
        XCTAssertEqual(ow, w); XCTAssertEqual(oh, h)
        XCTAssertLessThan(blue(out, w: ow, x: ow/2, y: 0), 75, "180: top now black")
        XCTAssertGreaterThan(blue(out, w: ow, x: ow/2, y: oh - 1), 180, "180: bottom now white")
    }

    func test_rotate270CW_topGoesLeft() {
        let w = 64, h = 48
        let (out, ow, oh) = NextVideoBlockResolver.rotateBGRA(src: topWhiteBottomBlack(w: w, h: h), width: w, height: h, quarterTurnsClockwise: 3)
        XCTAssertEqual(ow, h); XCTAssertEqual(oh, w)
        XCTAssertLessThan(blue(out, w: ow, x: ow - 1, y: oh/2), 75, "270°CW: black on the RIGHT")
        XCTAssertGreaterThan(blue(out, w: ow, x: 0, y: oh/2), 180, "270°CW: white (raw top) on the LEFT")
    }

    // MARK: - REAL preferredTransform end-to-end (the faithful orientation proof)
    //
    // These decode an ACTUAL .mp4 whose track carries a real `preferredTransform` (set via
    // `AVAssetWriterInput.transform`), through the full production resolver (VTCreateCGImage → bake).
    // This is the faithful test of the shipping path with a genuine rotation — no synthetic CGImage
    // (whose CGContext.makeImage Y-flip does not match the real video decoder, making byte-oracle
    // comparison unreliable). Asserts the displayed frame is upright + correctly dimensioned.

    private func px(_ bytes: [UInt8], bpr: Int, x: Int, y: Int) -> (Int, Int, Int) {
        let o = y * bpr + x * 4
        return (Int(bytes[o]), Int(bytes[o+1]), Int(bytes[o+2]))
    }

    /// Write a video whose RAW frames have a top-half/bottom-half split, with a given display
    /// `transform`. Returns the URL. `rawW×rawH` is the encoded (natural) size.
    private func writeSplitVideo(at url: URL, rawW: Int, rawH: Int, transform: CGAffineTransform,
                                 topBlue: UInt8, bottomBlue: UInt8) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: rawW, AVVideoHeightKey: rawH])
        input.expectsMediaDataInRealTime = false
        input.transform = transform   // → track.preferredTransform on the written asset
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: rawW, kCVPixelBufferHeightKey as String: rawH,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        guard writer.canAdd(input) else { throw NSError(domain: "NextVideoResolverTests", code: 20) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "NextVideoResolverTests", code: 21) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<8 {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, rawW, rawH, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
            guard let pb else { throw NSError(domain: "NextVideoResolverTests", code: 22) }
            CVPixelBufferLockBaseAddress(pb, [])
            let bpr = CVPixelBufferGetBytesPerRow(pb)
            let base = CVPixelBufferGetBaseAddress(pb)!
            for y in 0..<rawH {
                let v: UInt8 = (y < rawH / 2) ? topBlue : bottomBlue
                let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
                for x in 0..<rawW { let o = x * 4; row[o]=v; row[o+1]=v; row[o+2]=v; row[o+3]=255 }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            XCTAssertTrue(adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? NSError(domain: "NextVideoResolverTests", code: 23) }
    }

    func test_realTransform_identity_topStaysTop() async throws {
        let url = tempDir.appendingPathComponent("ident.mp4")
        // Landscape video, identity transform: raw top white, raw bottom black.
        try await writeSplitVideo(at: url, rawW: 128, rawH: 64, transform: .identity, topBlue: 255, bottomBlue: 0)
        let resolver = NextVideoBlockResolver(
            blockID: "b", mediaReference: "ref",
            window: NextVideoWindow(url: url, winStart: 0, winEnd: 0.2), maxPixelSize: 256)
        let p = try resolver.resolve(scenePlaybackSeconds: 0)
        defer { resolver.teardown() }
        XCTAssertEqual(p.dimensions.width, 128); XCTAssertEqual(p.dimensions.height, 64)
        let b = [UInt8](p.bytes); let bpr = p.dimensions.bytesPerRow
        XCTAssertGreaterThan(px(b, bpr: bpr, x: p.dimensions.width/2, y: 2).0, 180, "identity: top row white")
        XCTAssertLessThan(px(b, bpr: bpr, x: p.dimensions.width/2, y: p.dimensions.height - 3).0, 75, "identity: bottom row black")
    }

    func test_realTransform_portrait90_isUprightAndPortraitSized() async throws {
        let url = tempDir.appendingPathComponent("portrait.mp4")
        // iPhone-portrait: encoded landscape 128x64 with a 90° CW transform → displayed 64x128.
        let t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 64, ty: 0)
        // Raw top white / bottom black. Under 90° CW the raw TOP edge → display RIGHT column.
        try await writeSplitVideo(at: url, rawW: 128, rawH: 64, transform: t, topBlue: 255, bottomBlue: 0)
        let resolver = NextVideoBlockResolver(
            blockID: "b", mediaReference: "ref",
            window: NextVideoWindow(url: url, winStart: 0, winEnd: 0.2), maxPixelSize: 256)
        let p = try resolver.resolve(scenePlaybackSeconds: 0)
        defer { resolver.teardown() }
        // Dimensions must be PORTRAIT (rotated): 64 wide × 128 tall.
        XCTAssertEqual(p.dimensions.width, 64, "portrait: width = raw height")
        XCTAssertEqual(p.dimensions.height, 128, "portrait: height = raw width")
        let b = [UInt8](p.bytes); let bpr = p.dimensions.bytesPerRow
        // Raw top (white) → display RIGHT column; raw bottom (black) → display LEFT column.
        let leftMid = px(b, bpr: bpr, x: 2, y: p.dimensions.height/2).0
        let rightMid = px(b, bpr: bpr, x: p.dimensions.width - 3, y: p.dimensions.height/2).0
        XCTAssertGreaterThan(rightMid, 180, "portrait 90°CW: white (raw top) on the RIGHT — upright, not flipped")
        XCTAssertLessThan(leftMid, 75, "portrait 90°CW: black (raw bottom) on the LEFT")
    }

    func test_realTransform_portrait90_withDownsample_uprightAndScaled() async throws {
        let url = tempDir.appendingPathComponent("portrait_big.mp4")
        // Encoded landscape 256x144, 90° CW → display 144x256; downsample cap 80 → long edge 256→80.
        let t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 144, ty: 0)
        try await writeSplitVideo(at: url, rawW: 256, rawH: 144, transform: t, topBlue: 255, bottomBlue: 0)
        let resolver = NextVideoBlockResolver(
            blockID: "b", mediaReference: "ref",
            window: NextVideoWindow(url: url, winStart: 0, winEnd: 0.2), maxPixelSize: 80)
        let p = try resolver.resolve(scenePlaybackSeconds: 0)
        defer { resolver.teardown() }
        // Display 144x256, capped to long edge 80 → 45x80.
        XCTAssertEqual(p.dimensions.height, 80, "long edge capped to 80")
        XCTAssertEqual(p.dimensions.width, 45, "short edge scaled proportionally (144/256*80≈45)")
        let b = [UInt8](p.bytes); let bpr = p.dimensions.bytesPerRow
        let rightMid = px(b, bpr: bpr, x: p.dimensions.width - 3, y: p.dimensions.height/2).0
        let leftMid = px(b, bpr: bpr, x: 2, y: p.dimensions.height/2).0
        XCTAssertGreaterThan(rightMid, 180, "downsampled portrait: white (raw top) still on the RIGHT")
        XCTAssertLessThan(leftMid, 75, "downsampled portrait: black still on the LEFT")
    }

    // MARK: - Fail closed: missing / corrupt

    func test_missingFile_failsClosed() {
        let url = tempDir.appendingPathComponent("does_not_exist.mp4")
        let resolver = NextVideoBlockResolver(
            blockID: "b", mediaReference: "ref",
            window: NextVideoWindow(url: url, winStart: 0, winEnd: 1.0), maxPixelSize: 64)
        XCTAssertThrowsError(try resolver.resolve(scenePlaybackSeconds: 0)) { error in
            XCTAssertTrue(error is NextVideoFrameResolverError, "expected typed resolver error, got \(error)")
        }
        resolver.teardown()
    }

    func test_corruptFile_failsClosed() throws {
        let url = tempDir.appendingPathComponent("corrupt.mp4")
        try Data("not a real video".utf8).write(to: url)
        let resolver = NextVideoBlockResolver(
            blockID: "b", mediaReference: "ref",
            window: NextVideoWindow(url: url, winStart: 0, winEnd: 1.0), maxPixelSize: 64)
        XCTAssertThrowsError(try resolver.resolve(scenePlaybackSeconds: 0)) { error in
            XCTAssertTrue(error is NextVideoFrameResolverError, "expected typed resolver error, got \(error)")
        }
        resolver.teardown()
    }

    // MARK: - Fixture: a per-frame grey ramp video (each frame a distinct, monotone value)

    private func createRampVideo(at url: URL, frameCount: Int, fps: Int32, width: Int, height: Int) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ])
        guard writer.canAdd(input) else { throw NSError(domain: "NextVideoResolverTests", code: 1) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "NextVideoResolverTests", code: 2) }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            let buffer = try makeRampPixelBuffer(frame: frame, frameCount: frameCount, width: width, height: height)
            let pts = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: pts), "append frame \(frame)")
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "NextVideoResolverTests", code: 3)
        }
    }

    private func makeRampPixelBuffer(frame: Int, frameCount: Int, width: Int, height: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
        guard status == kCVReturnSuccess, let pb else { throw NSError(domain: "NextVideoResolverTests", code: 4) }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { throw NSError(domain: "NextVideoResolverTests", code: 5) }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        // Distinct monotone value per frame (well-separated so H.264 doesn't collapse neighbours).
        let value = UInt8((frame * 8) % 256)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let o = x * 4
                row[o + 0] = value           // B
                row[o + 1] = value           // G
                row[o + 2] = value           // R
                row[o + 3] = 255             // A
            }
        }
        return pb
    }
}
#endif
