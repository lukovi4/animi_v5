import AVFoundation
import XCTest
@testable import AnimiApp
@testable import TVECore

/// Tests for ExportMediaSnapshot and ExportBackgroundSnapshot.
final class ExportMediaSnapshotTests: XCTestCase {

    // MARK: - Test Infrastructure

    /// Creates a minimal valid .mp4 file (~1 frame) so AVURLAsset.duration returns > 0.
    private func createMinimalVideoFile(at url: URL, durationFrames: Int = 2, fps: Int32 = 30) async throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 16,
            AVVideoHeightKey: 16
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 16,
                kCVPixelBufferHeightKey as String: 16
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        guard let buffer = pixelBuffer else {
            throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create pixel buffer"])
        }
        for i in 0..<durationFrames {
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }

        input.markAsFinished()
        await writer.finishWriting()

        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "Test", code: 2, userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter failed"])
        }
    }

    private func makeMinimalRuntime() -> (CompiledScene, SceneRuntime) {
        let canvas = Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 100)
        let scene = Scene(
            schemaVersion: "1.0",
            sceneId: "test",
            canvas: canvas,
            background: nil,
            mediaBlocks: []
        )
        let runtime = SceneRuntime(
            scene: scene,
            canvas: canvas,
            blocks: [],
            durationFrames: 100,
            fps: 30
        )
        let compiled = CompiledScene(
            runtime: runtime,
            mergedAssetIndex: AssetIndexIR(),
            pathRegistry: PathRegistry(),
            bindingAssetIds: []
        )
        return (compiled, runtime)
    }

    // MARK: - ExportMediaSnapshot: Strict Video Contract

    /// Visible video slot with nil videoWindow throws missingVideoWindow.
    func test_visibleVideo_nilVideoWindow_throwsMissingVideoWindow() async throws {
        let (compiled, runtime) = makeMinimalRuntime()

        let projectsDir = try ProjectStore().projectsDirectoryURL()
        let relativePath = "Media/TestVideo/video_\(UUID().uuidString).mp4"
        let videoURL = projectsDir.appendingPathComponent(relativePath)
        try await createMinimalVideoFile(at: videoURL)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let mediaSlots: [String: SceneMediaSlot] = [
            "block1": SceneMediaSlot(
                asset: SceneMediaAsset(
                    mediaRef: MediaRef(storagePath: relativePath, mediaKind: .video),
                    placement: .defaultCover,
                    videoWindow: nil
                )
            )
        ]

        do {
            _ = try await ExportMediaSnapshot.build(
                compiledScene: compiled,
                mediaSlots: mediaSlots,
                mediaLocator: ProjectStore(),
                assetRegistry: ProjectAssetRegistry(),
                runtime: runtime
            )
            XCTFail("Expected missingVideoWindow error")
        } catch let error as ExportMediaError {
            if case .missingVideoWindow(let blockId) = error {
                XCTAssertEqual(blockId, "block1")
            } else {
                XCTFail("Expected missingVideoWindow, got \(error)")
            }
        }
    }

    /// Visible video with winEnd past actual duration throws invalidVideoSelection.
    func test_visibleVideo_windowExceedsDuration_throwsInvalidVideoSelection() async throws {
        let (compiled, runtime) = makeMinimalRuntime()

        let projectsDir = try ProjectStore().projectsDirectoryURL()
        let relativePath = "Media/TestVideo/video_\(UUID().uuidString).mp4"
        let videoURL = projectsDir.appendingPathComponent(relativePath)
        // Create a short video (~2 frames at 30fps ≈ 0.067s)
        try await createMinimalVideoFile(at: videoURL, durationFrames: 2, fps: 30)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        // Set trimEnd far past actual duration
        let mediaSlots: [String: SceneMediaSlot] = [
            "block1": .video(
                mediaRef: MediaRef(storagePath: relativePath, mediaKind: .video),
                placement: .defaultCover,
                videoWindow: PersistedVideoSelection(trimStart: 0, trimEnd: 999.0)
            )
        ]

        do {
            _ = try await ExportMediaSnapshot.build(
                compiledScene: compiled,
                mediaSlots: mediaSlots,
                mediaLocator: ProjectStore(),
                assetRegistry: ProjectAssetRegistry(),
                runtime: runtime
            )
            XCTFail("Expected invalidVideoSelection error")
        } catch let error as ExportMediaError {
            if case .invalidVideoSelection(let blockId, _) = error {
                XCTAssertEqual(blockId, "block1")
            } else {
                XCTFail("Expected invalidVideoSelection, got \(error)")
            }
        }
    }

    /// Hidden video slot is not included in videoRefs.
    func test_hiddenVideoSlot_notInVideoRefs() async throws {
        let (compiled, runtime) = makeMinimalRuntime()

        let projectsDir = try ProjectStore().projectsDirectoryURL()
        let relativePath = "Media/TestVideo/video_\(UUID().uuidString).mp4"
        let videoURL = projectsDir.appendingPathComponent(relativePath)
        try await createMinimalVideoFile(at: videoURL)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let mediaSlots: [String: SceneMediaSlot] = [
            "block1": .video(
                mediaRef: MediaRef(storagePath: relativePath, mediaKind: .video),
                visibility: false,
                placement: .defaultCover,
                videoWindow: PersistedVideoSelection(trimStart: 0, trimEnd: 5.0)
            )
        ]

        let snapshot = try await ExportMediaSnapshot.build(
            compiledScene: compiled,
            mediaSlots: mediaSlots,
            mediaLocator: ProjectStore(),
            assetRegistry: ProjectAssetRegistry(),
            runtime: runtime
        )

        XCTAssertTrue(snapshot.videoRefs.isEmpty, "Hidden video slot should not appear in videoRefs")
    }

    // MARK: - Corrupt Persisted Video (metadata load failure)

    /// Corrupt video file (exists but unreadable metadata) throws invalidVideoSelection.
    func test_corruptVideoFile_throwsInvalidVideoSelection() async throws {
        let (compiled, runtime) = makeMinimalRuntime()

        let projectsDir = try ProjectStore().projectsDirectoryURL()
        let relativePath = "Media/TestVideo/corrupt_\(UUID().uuidString).mp4"
        let corruptURL = projectsDir.appendingPathComponent(relativePath)

        // Write garbage bytes — file exists but AVURLAsset.load(.duration) will fail
        try FileManager.default.createDirectory(
            at: corruptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0xFF, count: 256).write(to: corruptURL)
        defer { try? FileManager.default.removeItem(at: corruptURL) }

        let mediaSlots: [String: SceneMediaSlot] = [
            "block1": .video(
                mediaRef: MediaRef(storagePath: relativePath, mediaKind: .video),
                placement: .defaultCover,
                videoWindow: PersistedVideoSelection(trimStart: 0, trimEnd: 5.0)
            )
        ]

        do {
            _ = try await ExportMediaSnapshot.build(
                compiledScene: compiled,
                mediaSlots: mediaSlots,
                mediaLocator: ProjectStore(),
                assetRegistry: ProjectAssetRegistry(),
                runtime: runtime
            )
            XCTFail("Expected invalidVideoSelection error for corrupt video")
        } catch let error as ExportMediaError {
            if case .invalidVideoSelection(let blockId, let reason) = error {
                XCTAssertEqual(blockId, "block1")
                XCTAssertTrue(reason.contains("duration"), "Reason should mention duration load failure, got: \(reason)")
            } else {
                XCTFail("Expected invalidVideoSelection, got \(error)")
            }
        }
    }

    // MARK: - ExportBackgroundSnapshot

    func test_buildFromNilOverride_returnsNil() {
        let result = ExportBackgroundSnapshot.build(
            from: nil,
            effectiveState: nil
        )
        XCTAssertNil(result, "Nil override should return nil snapshot")
    }

    func test_buildFromEmptyRegions_returnsNil() {
        let override = ProjectBackgroundOverride(regions: [:])
        let result = ExportBackgroundSnapshot.build(
            from: override,
            effectiveState: nil
        )
        XCTAssertNil(result)
    }
}
