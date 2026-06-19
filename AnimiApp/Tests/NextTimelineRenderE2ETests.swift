#if DEBUG
import XCTest
import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import AnimiApp
import AnimiEngineCore

/// CP5 — end-to-end multi-scene timeline render through AnimiEngineNext. This drives the FULL public
/// path the audit found untested at the app boundary:
///   decodeTimeline -> assembleTimeline -> TimelineEvaluator -> RenderInputResolver.resolve
///   -> RenderGraphCompiler.compile -> MetalRenderSession.execute -> BGRA8 RenderedFrame
/// using REAL bundled `full_image` compiled.tve packages + a real decoded photo. Requires a Metal
/// device; skips on machines without one.
final class NextTimelineRenderE2ETests: XCTestCase {

    /// Resolve a bundled scene folder URL (real compiled.tve) via the shipped library loader.
    private func sceneFolderURL(_ sceneTypeId: String) throws -> URL {
        let snapshot = try BundleSceneLibraryLoader().load()
        let scene = try XCTUnwrap(snapshot.scene(byId: sceneTypeId), "bundled scene '\(sceneTypeId)' missing")
        return try XCTUnwrap(scene.folderURL, "bundled scene '\(sceneTypeId)' has no folder URL")
    }

    /// Write a small solid-colour PNG to a temp file (a real, decodable photo).
    private func tempPhoto(_ name: String, w: Int = 64, h: Int = 64,
                           r: CGFloat, g: CGFloat, b: CGFloat) throws -> URL {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let image = try XCTUnwrap(ctx.makeImage())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp5e2e-\(name)-\(UUID().uuidString).png")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func scene(_ sceneTypeId: String, folder: URL, photo: URL,
                       transitionToNext: NextBridgeTransition?) -> NextBridgeTimelineScene {
        let inputs = NextBridgeInputs(
            sceneTypeId: sceneTypeId, sceneFolderURL: folder, variantOverrides: [:],
            blocks: [NextBridgeBlock(
                blockID: "block_01", mediaURL: photo,
                placement: NextBridgePlacement(fitModeRaw: "cover", offsetX: 0, offsetY: 0, userScale: 1, rotationDegrees: 0))],
            frameIndex: 0)
        return NextBridgeTimelineScene(scene: inputs, transitionToNext: transitionToNext)
    }

    /// A sampled BGRA8 pixel (0–255 channels, premultiplied) at a fractional position in the frame.
    private struct SampledPixel { let b, g, r, a: Int }
    private func sample(_ frame: NextBridgeBGRAFrame, fracX: Double, fracY: Double) -> SampledPixel {
        let x = min(frame.width - 1, max(0, Int(Double(frame.width) * fracX)))
        let y = min(frame.height - 1, max(0, Int(Double(frame.height) * fracY)))
        let off = y * frame.bytesPerRow + x * 4
        let bytes = [UInt8](frame.bytes)
        return SampledPixel(b: Int(bytes[off]), g: Int(bytes[off + 1]), r: Int(bytes[off + 2]), a: Int(bytes[off + 3]))
    }

    /// Find a frame index that the canonical evaluator reports as `.transition` (near the boundary).
    private func midTransitionFrame(structure: NextTimelineBridge.NextTimelineStructure) throws -> Int {
        let total = structure.totalFrames
        // Scan outward from the project centre for the first transition frame.
        let centre = total / 2
        for delta in 0..<total {
            for f in [centre - delta, centre + delta] where f >= 0 && f < total {
                let plan = try TimelineEvaluator.evaluate(structure.window, atFrame: try FrameIndex(value: Int64(f)))
                if case .transition = plan.body { return f }
            }
        }
        XCTFail("no transition frame found in project"); return centre
    }

    /// Render every frame across a two-scene fade and assert each is a complete, non-degenerate frame.
    /// This proves the `.single` AND `.transition` bodies both render end-to-end through Next.
    func test_twoScene_fade_rendersEveryFrameThroughNext() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let folder = try sceneFolderURL("full_image")
        let photoA = try tempPhoto("A", r: 1, g: 0, b: 0)
        let photoB = try tempPhoto("B", r: 0, g: 0, b: 1)
        defer { [photoA, photoB].forEach { try? FileManager.default.removeItem(at: $0) } }

        let fade = NextBridgeTransition(typeRaw: "fade", direction: nil, durationFrames: 14, easingRaw: "linear")
        let inputs = NextBridgeTimelineInputs(
            scenes: [
                scene("full_image", folder: folder, photo: photoA, transitionToNext: fade),
                scene("full_image", folder: folder, photo: photoB, transitionToNext: nil)
            ],
            nominalFrameIndex: 0, fps: 30)

        let sessionBox = try NextSingleSceneBridge.makeSession(device: device)
        let decoded = try NextTimelineBridge.decodeTimeline(inputs)
        XCTAssertEqual(decoded.count, 2)
        let ctx = try NextTimelineBridge.assembleTimeline(decoded: decoded, inputs: inputs, sessionBox: sessionBox)
        XCTAssertGreaterThan(ctx.totalFrames, 1, "two scenes → multi-frame project")

        // Render the whole project frame-by-frame; both single-scene and transition frames must
        // produce complete BGRA8 frames (never a typed throw, never a degenerate buffer).
        for f in 0..<ctx.totalFrames {
            let frame = try NextTimelineBridge.renderFrameBGRA(context: ctx, frameIndex: f)
            XCTAssertGreaterThan(frame.width, 0, "frame \(f) width")
            XCTAssertGreaterThan(frame.height, 0, "frame \(f) height")
            XCTAssertGreaterThanOrEqual(frame.bytesPerRow, frame.width * 4, "frame \(f) stride")
            XCTAssertEqual(frame.bytes.count, frame.bytesPerRow * frame.height, "frame \(f) byte count complete")
        }
    }

    /// All four slide directions render end-to-end through Next (canonical slide compositor path).
    func test_twoScene_slideAllDirections_renderMidTransition() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let folder = try sceneFolderURL("full_image")
        let photoA = try tempPhoto("sA", r: 0, g: 1, b: 0)
        let photoB = try tempPhoto("sB", r: 1, g: 1, b: 0)
        defer { [photoA, photoB].forEach { try? FileManager.default.removeItem(at: $0) } }
        let sessionBox = try NextSingleSceneBridge.makeSession(device: device)

        for dir in ["left", "right", "up", "down"] {
            let slide = NextBridgeTransition(typeRaw: "slide", direction: dir, durationFrames: 14, easingRaw: "easeInOut")
            let inputs = NextBridgeTimelineInputs(
                scenes: [
                    scene("full_image", folder: folder, photo: photoA, transitionToNext: slide),
                    scene("full_image", folder: folder, photo: photoB, transitionToNext: nil)
                ],
                nominalFrameIndex: 0, fps: 30)
            let decoded = try NextTimelineBridge.decodeTimeline(inputs)
            let ctx = try NextTimelineBridge.assembleTimeline(decoded: decoded, inputs: inputs, sessionBox: sessionBox)
            // Render a frame near the boundary (where the transition is active).
            let mid = ctx.totalFrames / 2
            let frame = try NextTimelineBridge.renderFrameBGRA(context: ctx, frameIndex: mid)
            XCTAssertGreaterThan(frame.width, 0, "slide \(dir) frame width")
            XCTAssertEqual(frame.bytes.count, frame.bytesPerRow * frame.height, "slide \(dir) frame complete")
        }
    }

    /// STRENGTHENED: render the exact mid-transition fade between a RED and a BLUE photo and assert
    /// the centre pixel is a genuine BLEND — both red and blue channels contribute, and it is neither
    /// pure red nor pure blue. This proves the fade actually composites both scenes (not just one).
    func test_fade_midTransition_centerPixelIsBlendOfBothScenes() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let folder = try sceneFolderURL("full_image")
        let red = try tempPhoto("red", r: 1, g: 0, b: 0)
        let blue = try tempPhoto("blue", r: 0, g: 0, b: 1)
        defer { [red, blue].forEach { try? FileManager.default.removeItem(at: $0) } }

        let fade = NextBridgeTransition(typeRaw: "fade", direction: nil, durationFrames: 14, easingRaw: "linear")
        let inputs = NextBridgeTimelineInputs(
            scenes: [
                scene("full_image", folder: folder, photo: red, transitionToNext: fade),
                scene("full_image", folder: folder, photo: blue, transitionToNext: nil)
            ],
            nominalFrameIndex: 0, fps: 30)

        let sessionBox = try NextSingleSceneBridge.makeSession(device: device)
        let decoded = try NextTimelineBridge.decodeTimeline(inputs)
        let structure = try NextTimelineBridge.buildTimelineStructureForTesting(decoded: decoded, inputs: inputs)
        let ctx = try NextTimelineBridge.assembleTimeline(decoded: decoded, inputs: inputs, sessionBox: sessionBox)

        let mid = try midTransitionFrame(structure: structure)
        // Confirm the evaluator really has a fade in progress (rational progress strictly inside (0,1)
        // so both scenes visibly contribute).
        let plan = try TimelineEvaluator.evaluate(structure.window, atFrame: try FrameIndex(value: Int64(mid)))
        guard case let .transition(t) = plan.body else { return XCTFail("frame \(mid) not a transition") }
        XCTAssertEqual(t.effectID.raw, "fade")
        XCTAssertGreaterThan(t.progressNumerator, 0, "progress > 0 so incoming (blue) contributes")
        XCTAssertLessThan(t.progressNumerator, t.progressDenominator, "progress < 1 so outgoing (red) contributes")

        let frame = try NextTimelineBridge.renderFrameBGRA(context: ctx, frameIndex: mid)
        let p = sample(frame, fracX: 0.5, fracY: 0.5)
        // Red photo → high R, low B; Blue photo → low R, high B. A real blend has BOTH present.
        XCTAssertGreaterThan(p.r, 20, "red scene contributes (R channel present): \(p)")
        XCTAssertGreaterThan(p.b, 20, "blue scene contributes (B channel present): \(p)")
        XCTAssertFalse(p.r > 230 && p.b < 25, "not pure red (outgoing-only): \(p)")
        XCTAssertFalse(p.b > 230 && p.r < 25, "not pure blue (incoming-only): \(p)")
    }

    /// STRENGTHENED: at a mid-transition slide frame, inspect the evaluated plan to PROVE the `.slide`
    /// effect with the correct direction is active, then render and confirm a complete frame. (Pixel
    /// region geometry depends on easing; the plan inspection is the deterministic proof.)
    func test_slide_midTransition_planHasCorrectDirectionAndRenders() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let folder = try sceneFolderURL("full_image")
        let green = try tempPhoto("g", r: 0, g: 1, b: 0)
        let yellow = try tempPhoto("y", r: 1, g: 1, b: 0)
        defer { [green, yellow].forEach { try? FileManager.default.removeItem(at: $0) } }
        let sessionBox = try NextSingleSceneBridge.makeSession(device: device)

        for dir in ["left", "right", "up", "down"] {
            let slide = NextBridgeTransition(typeRaw: "slide", direction: dir, durationFrames: 14, easingRaw: "easeInOut")
            let inputs = NextBridgeTimelineInputs(
                scenes: [
                    scene("full_image", folder: folder, photo: green, transitionToNext: slide),
                    scene("full_image", folder: folder, photo: yellow, transitionToNext: nil)
                ],
                nominalFrameIndex: 0, fps: 30)
            let decoded = try NextTimelineBridge.decodeTimeline(inputs)
            let structure = try NextTimelineBridge.buildTimelineStructureForTesting(decoded: decoded, inputs: inputs)
            let ctx = try NextTimelineBridge.assembleTimeline(decoded: decoded, inputs: inputs, sessionBox: sessionBox)

            let mid = try midTransitionFrame(structure: structure)
            let plan = try TimelineEvaluator.evaluate(structure.window, atFrame: try FrameIndex(value: Int64(mid)))
            guard case let .transition(t) = plan.body else { return XCTFail("slide \(dir): frame \(mid) not a transition") }
            XCTAssertEqual(t.effectID.raw, "slide", "slide \(dir): effect is slide")
            guard case let .identifier(value)? = t.parameters.value(for: "direction") else {
                return XCTFail("slide \(dir): no direction parameter in evaluated plan")
            }
            XCTAssertEqual(value, dir, "evaluated plan carries the correct slide direction")
            XCTAssertGreaterThan(t.progressNumerator, 0); XCTAssertLessThan(t.progressNumerator, t.progressDenominator)

            let frame = try NextTimelineBridge.renderFrameBGRA(context: ctx, frameIndex: mid)
            XCTAssertEqual(frame.bytes.count, frame.bytesPerRow * frame.height, "slide \(dir) frame complete")
        }
    }

    /// A `push` transition must fail closed (typed error) — no silent map to fade/slide, no render.
    /// The boundary-transition map happens in `assembleTimeline`, so the typed failure surfaces there
    /// (decode only needs the post-roll half-duration; the unsupported-type guard is at map time).
    func test_pushTransition_failsClosed() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let folder = try sceneFolderURL("full_image")
        let photoA = try tempPhoto("pA", r: 1, g: 0, b: 1)
        let photoB = try tempPhoto("pB", r: 0, g: 1, b: 1)
        defer { [photoA, photoB].forEach { try? FileManager.default.removeItem(at: $0) } }
        let push = NextBridgeTransition(typeRaw: "push", direction: "left", durationFrames: 14, easingRaw: "easeInOut")
        let inputs = NextBridgeTimelineInputs(
            scenes: [
                scene("full_image", folder: folder, photo: photoA, transitionToNext: push),
                scene("full_image", folder: folder, photo: photoB, transitionToNext: nil)
            ],
            nominalFrameIndex: 0, fps: 30)
        let sessionBox = try NextSingleSceneBridge.makeSession(device: device)
        let decoded = try NextTimelineBridge.decodeTimeline(inputs)   // post-roll only — does not map type
        XCTAssertThrowsError(try NextTimelineBridge.assembleTimeline(decoded: decoded, inputs: inputs, sessionBox: sessionBox)) { err in
            guard case NextTransitionMappingError.unsupportedTransitionType(let r) = err else {
                return XCTFail("expected unsupportedTransitionType, got \(err)")
            }
            XCTAssertEqual(r, "push")
        }
    }
}
#endif
