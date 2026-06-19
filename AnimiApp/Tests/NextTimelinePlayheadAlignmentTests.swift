#if DEBUG
import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import AnimiApp
import AnimiEngineCore

/// CP5 corrective — prove the app COMPRESSED playhead maps onto the canonical Next transition window.
///
/// The app owns a zone-based compressed timeline; the canonical Next evaluator owns its own centered
/// transition window in nominal ticks. Both must agree: when the app maps a compressed frame inside
/// its transition window to a NOMINAL project frame via `TimelinePlayheadMapper`, the canonical
/// evaluator at that nominal frame must report `.transition` (with the right outgoing/incoming scene
/// ids and a half-open rational progress); frames outside the window must be `.single`.
///
/// This drives the REAL bridge document/window (`buildTimelineStructureForTesting`) so the canonical
/// window is byte-identical to the one the render path evaluates. No Metal needed.
final class NextTimelinePlayheadAlignmentTests: XCTestCase {

    // MARK: - Fixtures

    /// `full_image` template nominal duration is 150 frames @ 30fps == the app default
    /// `baseDurationUs` (5_000_000µs). So an app scene with durationUs 5_000_000 lines up exactly
    /// with the canonical 150-frame scene the converter produces. (Verified in compiled.tve header.)
    private let sceneDurationUs: TimeUs = 5_000_000
    private let sceneDurationFrames = 150
    private let fps = 30

    private func sceneFolderURL(_ sceneTypeId: String) throws -> URL {
        let snapshot = try BundleSceneLibraryLoader().load()
        let scene = try XCTUnwrap(snapshot.scene(byId: sceneTypeId))
        return try XCTUnwrap(scene.folderURL)
    }

    private func tempPhoto(_ name: String) throws -> URL {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let image = try XCTUnwrap(ctx.makeImage())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cp5align-\(name)-\(UUID().uuidString).png")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil); XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    /// Build app scene `TimelineItem`s with stable ids, plus matching boundary transitions.
    private func appTimeline(sceneCount: Int, transition appTransition: AnimiApp.SceneTransition)
        -> (items: [TimelineItem], boundaries: [SceneBoundaryKey: AnimiApp.SceneTransition]) {
        var items: [TimelineItem] = []
        for _ in 0..<sceneCount {
            items.append(TimelineItem(payloadId: UUID(), kind: .scene, startUs: nil, durationUs: sceneDurationUs))
        }
        var boundaries: [SceneBoundaryKey: AnimiApp.SceneTransition] = [:]
        for i in 0..<(sceneCount - 1) {
            boundaries[SceneBoundaryKey(items[i].id, items[i + 1].id)] = appTransition
        }
        return (items, boundaries)
    }

    /// Build the canonical timeline structure for the SAME scene count + transition, via the real
    /// bridge document assembly (no Metal).
    private func canonicalStructure(sceneCount: Int, transition: NextBridgeTransition) throws
        -> NextTimelineBridge.NextTimelineStructure {
        let folder = try sceneFolderURL("full_image")
        var photos: [URL] = []
        for i in 0..<sceneCount { photos.append(try tempPhoto("s\(i)")) }
        addTeardownBlock { photos.forEach { try? FileManager.default.removeItem(at: $0) } }

        var scenes: [NextBridgeTimelineScene] = []
        for i in 0..<sceneCount {
            let inputs = NextBridgeInputs(
                sceneTypeId: "full_image", sceneFolderURL: folder, variantOverrides: [:],
                blocks: [NextBridgeBlock(blockID: "block_01", mediaURL: photos[i],
                                         placement: NextBridgePlacement(fitModeRaw: "cover", offsetX: 0, offsetY: 0, userScale: 1, rotationDegrees: 0))],
                frameIndex: 0)
            scenes.append(NextBridgeTimelineScene(scene: inputs, transitionToNext: i < sceneCount - 1 ? transition : nil))
        }
        let timelineInputs = NextBridgeTimelineInputs(scenes: scenes, nominalFrameIndex: 0, fps: fps)
        let decoded = try NextTimelineBridge.decodeTimeline(timelineInputs)
        return try NextTimelineBridge.buildTimelineStructureForTesting(decoded: decoded, inputs: timelineInputs)
    }

    // MARK: - Core alignment

    /// For every compressed frame in the app transition window, the mapped nominal frame must
    /// evaluate to `.transition` with the expected outgoing/incoming scene ids and a half-open
    /// rational progress. Frames clearly outside the window must be `.single`.
    private func assertAlignment(sceneCount: Int, appTransition: AnimiApp.SceneTransition, bridgeTransition: NextBridgeTransition) throws {
        let (items, boundaries) = appTimeline(sceneCount: sceneCount, transition: appTransition)
        let math = TimelineTransitionMath(sceneItems: items, boundaryTransitions: boundaries, fps: fps)
        let mapper = TimelinePlayheadMapper(math: math)
        let structure = try canonicalStructure(sceneCount: sceneCount, transition: bridgeTransition)

        XCTAssertEqual(structure.sceneInstanceIDs.count, sceneCount)
        XCTAssertEqual(structure.sceneNominalFrames, Array(repeating: sceneDurationFrames, count: sceneCount),
                       "canonical per-scene nominal frames must match the app 150f scenes")

        let windows = math.allTransitionWindows
        XCTAssertEqual(windows.count, sceneCount - 1, "one window per boundary")

        for window in windows {
            let outID = structure.sceneInstanceIDs[window.fromSceneIndex]
            let inID = structure.sceneInstanceIDs[window.toSceneIndex]

            // Every compressed frame strictly inside the app window must map to a canonical transition
            // frame with the right scene ids and a half-open progress.
            for compressed in window.startFrame..<window.endFrame {
                let nominal = mapper.nominalFrame(forCompressedFrame: compressed)
                let plan = try TimelineEvaluator.evaluate(structure.window, atFrame: try FrameIndex(value: Int64(nominal)))
                guard case let .transition(t) = plan.body else {
                    return XCTFail("compressed \(compressed) → nominal \(nominal): expected .transition, got .single (boundary \(window.fromSceneIndex)→\(window.toSceneIndex))")
                }
                XCTAssertEqual(t.outgoing.sceneID.raw, outID, "outgoing scene id at compressed \(compressed)")
                XCTAssertEqual(t.incoming.sceneID.raw, inID, "incoming scene id at compressed \(compressed)")
                XCTAssertGreaterThan(t.progressDenominator, 0)
                XCTAssertGreaterThanOrEqual(t.progressNumerator, 0, "progress ≥ 0")
                XCTAssertLessThan(t.progressNumerator, t.progressDenominator, "progress is half-open [0,1)")
            }

            // A frame well BEFORE the window (mid scene A) and well AFTER (mid scene B) must be single.
            let beforeCompressed = max(0, window.startFrame - 20)
            let afterCompressed = min(structure.totalFrames - 1, window.endFrame + 20)
            for (compressed, label) in [(beforeCompressed, "before"), (afterCompressed, "after")] {
                let nominal = mapper.nominalFrame(forCompressedFrame: compressed)
                let plan = try TimelineEvaluator.evaluate(structure.window, atFrame: try FrameIndex(value: Int64(nominal)))
                if case .transition = plan.body {
                    XCTFail("\(label) window: compressed \(compressed) → nominal \(nominal) unexpectedly .transition")
                }
            }
        }
    }

    // MARK: - Cases

    func test_twoScene_fade_alignment() throws {
        try assertAlignment(
            sceneCount: 2,
            appTransition: AnimiApp.SceneTransition(type: .fade, durationFrames: 14, easingPreset: .linear),
            bridgeTransition: NextBridgeTransition(typeRaw: "fade", direction: nil, durationFrames: 14, easingRaw: "linear"))
    }

    func test_twoScene_slide_alignment() throws {
        try assertAlignment(
            sceneCount: 2,
            appTransition: AnimiApp.SceneTransition(type: .slide(direction: .left), durationFrames: 14, easingPreset: .easeInOut),
            bridgeTransition: NextBridgeTransition(typeRaw: "slide", direction: "left", durationFrames: 14, easingRaw: "easeInOut"))
    }

    func test_threeScene_fade_alignment() throws {
        try assertAlignment(
            sceneCount: 3,
            appTransition: AnimiApp.SceneTransition(type: .fade, durationFrames: 14, easingPreset: .linear),
            bridgeTransition: NextBridgeTransition(typeRaw: "fade", direction: nil, durationFrames: 14, easingRaw: "linear"))
    }

    func test_threeScene_slide_alignment() throws {
        try assertAlignment(
            sceneCount: 3,
            appTransition: AnimiApp.SceneTransition(type: .slide(direction: .up), durationFrames: 14, easingPreset: .easeInOut),
            bridgeTransition: NextBridgeTransition(typeRaw: "slide", direction: "up", durationFrames: 14, easingRaw: "easeInOut"))
    }
}
#endif
