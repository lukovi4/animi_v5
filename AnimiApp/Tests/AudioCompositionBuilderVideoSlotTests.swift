import AVFoundation
import XCTest
@testable import AnimiApp
@testable import TVECore

/// Tests for AudioCompositionBuilder video slot audio insertion, volume semantics, and transition ramps.
final class AudioCompositionBuilderVideoSlotTests: XCTestCase {

    // MARK: - Helpers

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioBuilderVideoSlotTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDir = nil
        try await super.tearDown()
    }

    /// Creates a minimal video file WITH an audio track.
    /// First creates a silent WAV, then muxes it with video via AVAssetExportSession.
    private func createTestVideoWithAudio(duration: Double = 2.0) async throws -> URL {
        // 1. Create silent WAV file
        let wavURL = tempDir.appendingPathComponent("\(UUID().uuidString).wav")
        let sampleRate: Int = 44100
        let totalSamples = Int(duration * Double(sampleRate))
        let numChannels: Int = 1
        let bitsPerSample: Int = 16
        let byteRate = sampleRate * numChannels * bitsPerSample / 8
        let blockAlign = numChannels * bitsPerSample / 8
        let dataSize = totalSamples * blockAlign

        var wavData = Data()
        // RIFF header
        wavData.append(contentsOf: "RIFF".utf8)
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(36 + dataSize).littleEndian) { Array($0) })
        wavData.append(contentsOf: "WAVE".utf8)
        // fmt chunk
        wavData.append(contentsOf: "fmt ".utf8)
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // PCM
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(numChannels).littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(byteRate).littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(blockAlign).littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(bitsPerSample).littleEndian) { Array($0) })
        // data chunk
        wavData.append(contentsOf: "data".utf8)
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })
        wavData.append(Data(count: dataSize)) // silence
        try wavData.write(to: wavURL)

        // 2. Create video-only file
        let videoOnlyURL = try await createTestVideoWithoutAudio(duration: duration)

        // 3. Mux video + audio via AVMutableComposition → export
        let videoAsset = AVURLAsset(url: videoOnlyURL)
        let audioAsset = AVURLAsset(url: wavURL)

        let composition = AVMutableComposition()

        if let videoTrack = videoAsset.tracks(withMediaType: .video).first,
           let compVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let range = CMTimeRange(start: .zero, duration: videoAsset.duration)
            try compVideoTrack.insertTimeRange(range, of: videoTrack, at: .zero)
        }

        if let audioTrack = audioAsset.tracks(withMediaType: .audio).first,
           let compAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let range = CMTimeRange(start: .zero, duration: audioAsset.duration)
            try compAudioTrack.insertTimeRange(range, of: audioTrack, at: .zero)
        }

        let outputURL = tempDir.appendingPathComponent("\(UUID().uuidString).mp4")

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw NSError(domain: "Test", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"])
        }
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        await exportSession.export()

        guard exportSession.status == .completed else {
            throw exportSession.error ?? NSError(domain: "Test", code: -4)
        }

        // Verify it has audio
        let resultAsset = AVURLAsset(url: outputURL)
        guard !resultAsset.tracks(withMediaType: .audio).isEmpty else {
            throw NSError(domain: "Test", code: -5, userInfo: [NSLocalizedDescriptionKey: "Muxed file has no audio track"])
        }

        return outputURL
    }

    /// Creates a simple video file WITHOUT audio.
    private func createTestVideoWithoutAudio(duration: Double = 1.0) async throws -> URL {
        let url = tempDir.appendingPathComponent("\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 64
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let fps = 30.0
        let frameCount = Int(duration * fps)
        for i in 0..<max(1, frameCount) {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &pb)
            guard let buffer = pb else { continue }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? NSError(domain: "Test", code: -1) }
        return url
    }

    private func makeBlock(blockId: String, startFrame: Int, endFrame: Int) -> BlockRuntime {
        let timing = BlockTiming(startFrame: startFrame, endFrame: endFrame)
        let baseline = BindingBaselineRuntime(
            boundAssetId: "test|placeholder",
            contentSizeLocal: SizeD(width: 100, height: 100)
        )
        let inputGeom = MediaInputGeometryRuntime(
            placementRectLocal: RectD(x: 0, y: 0, width: 100, height: 100)
        )
        return BlockRuntime(
            blockId: blockId,
            zIndex: 0,
            orderIndex: 0,
            rectCanvas: RectD(x: 0, y: 0, width: 100, height: 100),
            bindingBaseline: baseline,
            mediaInputGeometry: inputGeom,
            timing: timing,
            containerClip: .slotRect,
            hitTestMode: nil,
            selectedVariantId: "default",
            editVariantId: "default",
            variants: []
        )
    }

    private func makeRuntime(blocks: [BlockRuntime], durationFrames: Int, fps: Int = 30) -> SceneRuntime {
        let canvas = Canvas(width: 1080, height: 1920, fps: fps, durationFrames: durationFrames)
        let scene = Scene(schemaVersion: "1.0", sceneId: "test", canvas: canvas, background: nil, mediaBlocks: [])
        return SceneRuntime(scene: scene, canvas: canvas, blocks: blocks, durationFrames: durationFrames, fps: fps)
    }

    private func makeSceneData(
        sceneIndex: Int,
        blocks: [BlockRuntime],
        videoSelections: [String: VideoSelection],
        durationFrames: Int
    ) -> TimelineCompositionEngine.SceneAudioExportData {
        let runtime = makeRuntime(blocks: blocks, durationFrames: durationFrames)
        return TimelineCompositionEngine.SceneAudioExportData(
            sceneIndex: sceneIndex,
            runtime: runtime,
            videoSelections: videoSelections
        )
    }

    private func makeSimpleMath(sceneDurationFrames: Int, sceneCount: Int = 1) -> TimelineTransitionMath {
        var items: [TimelineItem] = []
        for _ in 0..<sceneCount {
            let pid = UUID()
            items.append(TimelineItem(payloadId: pid, kind: .scene, startUs: nil, durationUs: Int64(sceneDurationFrames) * 1_000_000 / 30))
        }
        return TimelineTransitionMath(sceneItems: items, boundaryTransitions: [:], fps: 30)
    }

    private func makeTransitionMath(sceneDurationFrames: [Int], transitionFrames: Int) -> TimelineTransitionMath {
        var items: [TimelineItem] = []
        for dur in sceneDurationFrames {
            let pid = UUID()
            items.append(TimelineItem(payloadId: pid, kind: .scene, startUs: nil, durationUs: Int64(dur) * 1_000_000 / 30))
        }
        var boundaries: [SceneBoundaryKey: SceneTransition] = [:]
        for i in 0..<(items.count - 1) {
            let key = SceneBoundaryKey(items[i].id, items[i + 1].id)
            boundaries[key] = SceneTransition(type: .fade, durationFrames: transitionFrames, easingPreset: .easeInOut)
        }
        return TimelineTransitionMath(sceneItems: items, boundaryTransitions: boundaries, fps: 30)
    }

    // MARK: - Tests

    func test_unmutedVideoSlot_insertsAudioTrack() async throws {
        let url = try await createTestVideoWithAudio(duration: 2.0)
        let selection = VideoSelection(url: url, trimStart: 0, trimEnd: 2.0, isMuted: false, volume: 0.8)
        let block = makeBlock(blockId: "b1", startFrame: 0, endFrame: 60)
        let math = makeSimpleMath(sceneDurationFrames: 60)
        let plan = AudioExportPlan(items: [], includeOriginalFromVideoSlots: true)

        let data = makeSceneData(sceneIndex: 0, blocks: [block], videoSelections: ["b1": selection], durationFrames: 60)
        let builder = AudioCompositionBuilder()
        let result = try builder.buildTimeline(sceneData: [data], transitionMath: math, fps: 30, plan: plan)

        let audioTracks = result.composition.tracks(withMediaType: .audio)
        XCTAssertFalse(audioTracks.isEmpty, "Unmuted video slot should produce at least one audio track")
    }

    func test_mutedVideoSlot_excluded() async throws {
        let url = try await createTestVideoWithAudio(duration: 2.0)
        let selection = VideoSelection(url: url, trimStart: 0, trimEnd: 2.0, isMuted: true, volume: 1.0)
        let block = makeBlock(blockId: "b1", startFrame: 0, endFrame: 60)
        let math = makeSimpleMath(sceneDurationFrames: 60)
        let plan = AudioExportPlan(items: [], includeOriginalFromVideoSlots: true)

        let data = makeSceneData(sceneIndex: 0, blocks: [block], videoSelections: ["b1": selection], durationFrames: 60)
        let builder = AudioCompositionBuilder()
        let result = try builder.buildTimeline(sceneData: [data], transitionMath: math, fps: 30, plan: plan)

        let audioTracks = result.composition.tracks(withMediaType: .audio)
        XCTAssertTrue(audioTracks.isEmpty, "Muted video slot should produce no audio tracks")
    }

    func test_volume0_producesNoTrack() async throws {
        let url = try await createTestVideoWithAudio(duration: 2.0)
        let selection = VideoSelection(url: url, trimStart: 0, trimEnd: 2.0, isMuted: false, volume: 0.0)
        let block = makeBlock(blockId: "b1", startFrame: 0, endFrame: 60)
        let math = makeSimpleMath(sceneDurationFrames: 60)
        let plan = AudioExportPlan(items: [], includeOriginalFromVideoSlots: true)

        let data = makeSceneData(sceneIndex: 0, blocks: [block], videoSelections: ["b1": selection], durationFrames: 60)
        let builder = AudioCompositionBuilder()
        let result = try builder.buildTimeline(sceneData: [data], transitionMath: math, fps: 30, plan: plan)

        let audioTracks = result.composition.tracks(withMediaType: .audio)
        XCTAssertTrue(audioTracks.isEmpty, "Volume=0 should skip track entirely")
    }

    func test_trimStartEnd_respected() async throws {
        let url = try await createTestVideoWithAudio(duration: 4.0)
        // Trim to middle 2s
        let selection = VideoSelection(url: url, trimStart: 1.0, trimEnd: 3.0, isMuted: false, volume: 1.0)
        let block = makeBlock(blockId: "b1", startFrame: 0, endFrame: 60)
        let math = makeSimpleMath(sceneDurationFrames: 60)
        let plan = AudioExportPlan(items: [], includeOriginalFromVideoSlots: true)

        let data = makeSceneData(sceneIndex: 0, blocks: [block], videoSelections: ["b1": selection], durationFrames: 60)
        let builder = AudioCompositionBuilder()
        let result = try builder.buildTimeline(sceneData: [data], transitionMath: math, fps: 30, plan: plan)

        let audioTracks = result.composition.tracks(withMediaType: .audio)
        XCTAssertFalse(audioTracks.isEmpty, "Trimmed video slot should still insert audio")

        // Duration should be min(trimDuration=2s, blockDuration=2s)
        let trackDuration = CMTimeGetSeconds(result.composition.duration)
        XCTAssertGreaterThan(trackDuration, 0)
        XCTAssertLessThanOrEqual(trackDuration, 2.1, "Duration should respect trim window")
    }

    func test_twoVisibleVideoBlocks_bothInserted() async throws {
        let url1 = try await createTestVideoWithAudio(duration: 2.0)
        let url2 = try await createTestVideoWithAudio(duration: 2.0)
        let sel1 = VideoSelection(url: url1, trimStart: 0, trimEnd: 2.0, isMuted: false, volume: 1.0)
        let sel2 = VideoSelection(url: url2, trimStart: 0, trimEnd: 2.0, isMuted: false, volume: 0.5)
        let block1 = makeBlock(blockId: "b1", startFrame: 0, endFrame: 60)
        let block2 = makeBlock(blockId: "b2", startFrame: 0, endFrame: 60)
        let math = makeSimpleMath(sceneDurationFrames: 60)
        let plan = AudioExportPlan(items: [], includeOriginalFromVideoSlots: true)

        let data = makeSceneData(
            sceneIndex: 0,
            blocks: [block1, block2],
            videoSelections: ["b1": sel1, "b2": sel2],
            durationFrames: 60
        )
        let builder = AudioCompositionBuilder()
        let result = try builder.buildTimeline(sceneData: [data], transitionMath: math, fps: 30, plan: plan)

        let audioTracks = result.composition.tracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 2, "Both video blocks should insert separate audio tracks")
    }

    func test_hiddenVideoSlot_excluded() async throws {
        // Hidden slot: block exists in runtime but NOT in videoSelections
        // (buildVideoSelections filters out visibility=false slots)
        let block = makeBlock(blockId: "b1", startFrame: 0, endFrame: 60)
        let math = makeSimpleMath(sceneDurationFrames: 60)
        let plan = AudioExportPlan(items: [], includeOriginalFromVideoSlots: true)

        // Empty videoSelections = slot was hidden/filtered out
        let data = makeSceneData(sceneIndex: 0, blocks: [block], videoSelections: [:], durationFrames: 60)
        let builder = AudioCompositionBuilder()
        let result = try builder.buildTimeline(sceneData: [data], transitionMath: math, fps: 30, plan: plan)

        let audioTracks = result.composition.tracks(withMediaType: .audio)
        XCTAssertTrue(audioTracks.isEmpty, "Hidden video slot should produce no audio tracks")
    }

    func test_invalidVideoSelection_excluded() async throws {
        // VideoSelection with isValid=false (trimEnd < trimStart) should be skipped
        let url = try await createTestVideoWithAudio(duration: 2.0)
        let selection = VideoSelection(url: url, trimStart: 1.0, trimEnd: 0.5, isMuted: false, volume: 1.0)
        let block = makeBlock(blockId: "b1", startFrame: 0, endFrame: 60)
        let math = makeSimpleMath(sceneDurationFrames: 60)
        let plan = AudioExportPlan(items: [], includeOriginalFromVideoSlots: true)

        let data = makeSceneData(sceneIndex: 0, blocks: [block], videoSelections: ["b1": selection], durationFrames: 60)
        let builder = AudioCompositionBuilder()
        let result = try builder.buildTimeline(sceneData: [data], transitionMath: math, fps: 30, plan: plan)

        let audioTracks = result.composition.tracks(withMediaType: .audio)
        XCTAssertTrue(audioTracks.isEmpty, "Invalid video selection should produce no audio tracks")
    }

    // MARK: - Transition Ramp Tests

    func test_transitionRamp_outgoing_fadeOut() async throws {
        let url = try await createTestVideoWithAudio(duration: 4.0)
        let selection = VideoSelection(url: url, trimStart: 0, trimEnd: 4.0, isMuted: false, volume: 1.0)
        let block = makeBlock(blockId: "b1", startFrame: 0, endFrame: 120) // 4s at 30fps

        let math = makeTransitionMath(sceneDurationFrames: [120, 120], transitionFrames: 30) // 1s transition
        let plan = AudioExportPlan(items: [], includeOriginalFromVideoSlots: true)

        let data = makeSceneData(sceneIndex: 0, blocks: [block], videoSelections: ["b1": selection], durationFrames: 120)
        let builder = AudioCompositionBuilder()
        let result = try builder.buildTimeline(sceneData: [data], transitionMath: math, fps: 30, plan: plan)

        // Should have audio track with mix parameters (ramp applied)
        XCTAssertNotNil(result.audioMix, "Transition ramp should produce an audio mix")
        let audioTracks = result.composition.tracks(withMediaType: .audio)
        XCTAssertFalse(audioTracks.isEmpty, "Outgoing scene should have audio track")
    }

    func test_transitionRamp_incoming_fadeIn() async throws {
        let url = try await createTestVideoWithAudio(duration: 4.0)
        let selection = VideoSelection(url: url, trimStart: 0, trimEnd: 4.0, isMuted: false, volume: 1.0)
        let block = makeBlock(blockId: "b2", startFrame: 0, endFrame: 120)

        let math = makeTransitionMath(sceneDurationFrames: [120, 120], transitionFrames: 30)
        let plan = AudioExportPlan(items: [], includeOriginalFromVideoSlots: true)

        // Scene index 1 = incoming
        let data = makeSceneData(sceneIndex: 1, blocks: [block], videoSelections: ["b2": selection], durationFrames: 120)
        let builder = AudioCompositionBuilder()
        let result = try builder.buildTimeline(sceneData: [data], transitionMath: math, fps: 30, plan: plan)

        XCTAssertNotNil(result.audioMix, "Incoming scene transition ramp should produce audio mix")
        let audioTracks = result.composition.tracks(withMediaType: .audio)
        XCTAssertFalse(audioTracks.isEmpty, "Incoming scene should have audio track")
    }

    func test_transitionRamp_middleScene_bothRamps() async throws {
        let url = try await createTestVideoWithAudio(duration: 4.0)
        let selection = VideoSelection(url: url, trimStart: 0, trimEnd: 4.0, isMuted: false, volume: 1.0)
        let block = makeBlock(blockId: "b2", startFrame: 0, endFrame: 120)

        let math = makeTransitionMath(sceneDurationFrames: [120, 120, 120], transitionFrames: 30)
        let plan = AudioExportPlan(items: [], includeOriginalFromVideoSlots: true)

        // Scene index 1 in a 3-scene timeline = middle scene (incoming from 0, outgoing to 2)
        let data = makeSceneData(sceneIndex: 1, blocks: [block], videoSelections: ["b2": selection], durationFrames: 120)
        let builder = AudioCompositionBuilder()
        let result = try builder.buildTimeline(sceneData: [data], transitionMath: math, fps: 30, plan: plan)

        XCTAssertNotNil(result.audioMix, "Middle scene should have audio mix with both ramps")
        let audioTracks = result.composition.tracks(withMediaType: .audio)
        XCTAssertFalse(audioTracks.isEmpty)
    }

    func test_transitionRamp_partialIntersection() async throws {
        // Block that starts partway through transition window
        let url = try await createTestVideoWithAudio(duration: 2.0)
        let selection = VideoSelection(url: url, trimStart: 0, trimEnd: 2.0, isMuted: false, volume: 1.0)
        // Block starts at frame 90 in a 120-frame scene with 30-frame transition at the end
        let block = makeBlock(blockId: "b1", startFrame: 90, endFrame: 120)

        let math = makeTransitionMath(sceneDurationFrames: [120, 120], transitionFrames: 30)
        let plan = AudioExportPlan(items: [], includeOriginalFromVideoSlots: true)

        let data = makeSceneData(sceneIndex: 0, blocks: [block], videoSelections: ["b1": selection], durationFrames: 120)
        let builder = AudioCompositionBuilder()
        let result = try builder.buildTimeline(sceneData: [data], transitionMath: math, fps: 30, plan: plan)

        // Should still insert audio with partial ramp
        let audioTracks = result.composition.tracks(withMediaType: .audio)
        XCTAssertFalse(audioTracks.isEmpty, "Partial intersection should still produce audio")
    }

    // MARK: - Stretched Scene Tests

    func test_stretchedScene_audioUsesTimelineDuration() async throws {
        // Native scene: 5s (150 frames), stretched to 10s (300 frames on timeline)
        // Video: 10s available. Block fills entire native scene (0..150).
        // Without stretch fix: audio would be 5s. With fix: should be 10s.
        let url = try await createTestVideoWithAudio(duration: 10.0)
        let selection = VideoSelection(url: url, trimStart: 0, trimEnd: 10.0, isMuted: false, volume: 1.0)
        let nativeFrames = 150
        let stretchedFrames = 300
        let block = makeBlock(blockId: "b1", startFrame: 0, endFrame: nativeFrames)
        // Timeline item has stretched duration (300 frames = 10s)
        let math = makeSimpleMath(sceneDurationFrames: stretchedFrames, sceneCount: 1)
        let plan = AudioExportPlan(items: [], includeOriginalFromVideoSlots: true)

        let data = makeSceneData(sceneIndex: 0, blocks: [block], videoSelections: ["b1": selection], durationFrames: nativeFrames)
        let builder = AudioCompositionBuilder()
        let result = try builder.buildTimeline(sceneData: [data], transitionMath: math, fps: 30, plan: plan)

        let audioTracks = result.composition.tracks(withMediaType: .audio)
        XCTAssertFalse(audioTracks.isEmpty, "Stretched scene should produce audio")

        let trackDuration = CMTimeGetSeconds(result.composition.duration)
        // Should be closer to 10s (stretched), not 5s (native)
        XCTAssertGreaterThan(trackDuration, 7.0, "Audio duration should reflect stretched scene duration, not native (\(trackDuration)s)")
    }

    func test_singleScene_stretched_audioExtendsToSpan() async throws {
        // CP7.5 single-scene path (no transitionMath): native 5s (150f) stretched to 10s (300f) via
        // the new `stretchedSceneDurationFrames` param. Video-slot audio (block fills native scene)
        // must extend to ~10s, not stop at 5s.
        let url = try await createTestVideoWithAudio(duration: 10.0)
        let selection = VideoSelection(url: url, trimStart: 0, trimEnd: 10.0, isMuted: false, volume: 1.0)
        let nativeFrames = 150
        let block = makeBlock(blockId: "b1", startFrame: 0, endFrame: nativeFrames)
        let runtime = makeRuntime(blocks: [block], durationFrames: nativeFrames)
        let plan = AudioExportPlan(items: [], includeOriginalFromVideoSlots: true)

        let builder = AudioCompositionBuilder()
        // Unstretched build → ~5s.
        let nativeResult = try builder.build(
            runtime: runtime, fps: 30, videoSelectionsByBlockId: ["b1": selection], plan: plan)
        XCTAssertLessThan(CMTimeGetSeconds(nativeResult.composition.duration), 6.0, "native build ≈ 5s")
        // Stretched build → ~10s.
        let stretchedResult = try builder.build(
            runtime: runtime, fps: 30, videoSelectionsByBlockId: ["b1": selection], plan: plan,
            stretchedSceneDurationFrames: 300)
        XCTAssertGreaterThan(CMTimeGetSeconds(stretchedResult.composition.duration), 7.0,
                             "stretched single-scene audio extends to the span, not native 5s")
    }

    func test_stretchedScene_partialBlock_correctDuration() async throws {
        // Block 30..90, native=150, stretched=300
        // Partial block doesn't reach native end → native timing, no stretch
        // Expected: start=1.0s, duration=2.0s (60 frames / 30fps)
        let url = try await createTestVideoWithAudio(duration: 10.0)
        let selection = VideoSelection(url: url, trimStart: 0, trimEnd: 10.0, isMuted: false, volume: 1.0)
        let block = makeBlock(blockId: "b1", startFrame: 30, endFrame: 90)
        let math = makeSimpleMath(sceneDurationFrames: 300, sceneCount: 1)
        let plan = AudioExportPlan(items: [], includeOriginalFromVideoSlots: true)

        let data = makeSceneData(sceneIndex: 0, blocks: [block], videoSelections: ["b1": selection], durationFrames: 150)
        let builder = AudioCompositionBuilder()
        let result = try builder.buildTimeline(sceneData: [data], transitionMath: math, fps: 30, plan: plan)

        let audioTracks = result.composition.tracks(withMediaType: .audio)
        XCTAssertFalse(audioTracks.isEmpty, "Partial block should produce audio")

        let trackDuration = CMTimeGetSeconds(result.composition.duration)
        // start at 1.0s + duration 2.0s = ends at 3.0s
        XCTAssertEqual(trackDuration, 3.0, accuracy: 0.1,
                       "Partial block should use native timing (2s duration), not scaled (\(trackDuration)s)")
    }

    func test_stretchedScene_blockStartTime_notScaled() async throws {
        // Block 30..150, native=150, stretched=300
        // Block reaches native end → extends to timeline end (300 frames = 10s)
        // Expected: start=1.0s (frame 30/30fps), duration=9.0s (300-30=270 frames)
        let url = try await createTestVideoWithAudio(duration: 10.0)
        let selection = VideoSelection(url: url, trimStart: 0, trimEnd: 10.0, isMuted: false, volume: 1.0)
        let block = makeBlock(blockId: "b1", startFrame: 30, endFrame: 150)
        let math = makeSimpleMath(sceneDurationFrames: 300, sceneCount: 1)
        let plan = AudioExportPlan(items: [], includeOriginalFromVideoSlots: true)

        let data = makeSceneData(sceneIndex: 0, blocks: [block], videoSelections: ["b1": selection], durationFrames: 150)
        let builder = AudioCompositionBuilder()
        let result = try builder.buildTimeline(sceneData: [data], transitionMath: math, fps: 30, plan: plan)

        let audioTracks = result.composition.tracks(withMediaType: .audio)
        XCTAssertFalse(audioTracks.isEmpty)

        // Audio should start at 1.0s and end at 10.0s (total composition duration)
        let trackDuration = CMTimeGetSeconds(result.composition.duration)
        XCTAssertEqual(trackDuration, 10.0, accuracy: 0.1,
                       "Block reaching native end should extend to timeline end (\(trackDuration)s)")
    }

    func test_outgoingTransition_audioExtendsThroughTail() async throws {
        // Scene A: 120f (4s), transition: 30f (1s), block: 0..120
        // Transition window: start=105, end=135
        // Scene A compressed end = 120, so outgoing tail = 135-120 = 15 frames
        // Block reaches native end → extends to 120 + 15 = 135 frames
        // Expected duration: 135/30 = 4.5s
        let url = try await createTestVideoWithAudio(duration: 5.0)
        let selection = VideoSelection(url: url, trimStart: 0, trimEnd: 5.0, isMuted: false, volume: 1.0)
        let block = makeBlock(blockId: "b1", startFrame: 0, endFrame: 120)
        let math = makeTransitionMath(sceneDurationFrames: [120, 120], transitionFrames: 30)
        let plan = AudioExportPlan(items: [], includeOriginalFromVideoSlots: true)

        let data = makeSceneData(sceneIndex: 0, blocks: [block], videoSelections: ["b1": selection], durationFrames: 120)
        let builder = AudioCompositionBuilder()
        let result = try builder.buildTimeline(sceneData: [data], transitionMath: math, fps: 30, plan: plan)

        let audioTracks = result.composition.tracks(withMediaType: .audio)
        XCTAssertFalse(audioTracks.isEmpty, "Outgoing scene should have audio")

        let trackDuration = CMTimeGetSeconds(result.composition.duration)
        XCTAssertEqual(trackDuration, 4.5, accuracy: 0.1,
                       "Audio should extend through transition tail to 4.5s (\(trackDuration)s)")
    }

    func test_outgoingTransition_partialBlock_noTailExtension() async throws {
        // Block 0..90 in 120f scene with 30f transition
        // Block doesn't reach native end (90 < 120) → no tail extension
        // Expected duration: 90/30 = 3.0s exactly
        let url = try await createTestVideoWithAudio(duration: 5.0)
        let selection = VideoSelection(url: url, trimStart: 0, trimEnd: 5.0, isMuted: false, volume: 1.0)
        let block = makeBlock(blockId: "b1", startFrame: 0, endFrame: 90)
        let math = makeTransitionMath(sceneDurationFrames: [120, 120], transitionFrames: 30)
        let plan = AudioExportPlan(items: [], includeOriginalFromVideoSlots: true)

        let data = makeSceneData(sceneIndex: 0, blocks: [block], videoSelections: ["b1": selection], durationFrames: 120)
        let builder = AudioCompositionBuilder()
        let result = try builder.buildTimeline(sceneData: [data], transitionMath: math, fps: 30, plan: plan)

        let audioTracks = result.composition.tracks(withMediaType: .audio)
        XCTAssertFalse(audioTracks.isEmpty)

        let trackDuration = CMTimeGetSeconds(result.composition.duration)
        XCTAssertEqual(trackDuration, 3.0, accuracy: 0.1,
                       "Partial block should not get transition tail extension (\(trackDuration)s)")
    }

    func test_stretchedScene_withTransition_combined() async throws {
        // Stretched scene A: native=90 (3s), stretched=180 (6s), transition=30f (1s)
        // Block: 0..90 (full scene, reaches native end)
        // Transition window: start = 180 - 15 = 165, end = 165 + 30 = 195
        // Scene A end = 180, so outgoing tail = 195 - 180 = 15
        // localEnd = 180 + 15 = 195, blockVisibility = 195/30 = 6.5s
        let url = try await createTestVideoWithAudio(duration: 8.0)
        let selection = VideoSelection(url: url, trimStart: 0, trimEnd: 8.0, isMuted: false, volume: 1.0)
        let block = makeBlock(blockId: "b1", startFrame: 0, endFrame: 90)
        let math = makeTransitionMath(sceneDurationFrames: [180, 180], transitionFrames: 30)
        let plan = AudioExportPlan(items: [], includeOriginalFromVideoSlots: true)

        let data = makeSceneData(sceneIndex: 0, blocks: [block], videoSelections: ["b1": selection], durationFrames: 90)
        let builder = AudioCompositionBuilder()
        let result = try builder.buildTimeline(sceneData: [data], transitionMath: math, fps: 30, plan: plan)

        let audioTracks = result.composition.tracks(withMediaType: .audio)
        XCTAssertFalse(audioTracks.isEmpty)

        let trackDuration = CMTimeGetSeconds(result.composition.duration)
        XCTAssertEqual(trackDuration, 6.5, accuracy: 0.1,
                       "Stretched scene with transition should extend through tail (\(trackDuration)s)")
    }
}
