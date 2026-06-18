import XCTest
import Foundation
import Metal
import AnimiEngineCore
import AnimiEngineRenderModel
import AnimiEngineRenderGraph
@testable import AnimiEngineMetalRender

/// Task-003 plan §13 — Metal lifecycle, typed errors, preflight, execution guard, upload, and the
/// `ceilDiv` Int64-boundary tests. Defines the **test-only** `StubFailingSubmitter` (Rev-4 correction #3):
/// production `CommandSubmitter.swift` carries only the protocol, `CommandCompletion`, and
/// `RealCommandSubmitter`.
final class MetalResourceOwnershipTests: XCTestCase {

    // MARK: - Test-only failing submitter (Rev-4 correction #3)

    /// Wraps a real submitter for `makeCommandBuffer`/encoding but maps the completion to a deterministic
    /// `.failed`, without claiming to hand-mark a real `MTLCommandBuffer` failed (plan §13.2).
    struct StubFailingSubmitter: CommandSubmitter {
        let inner: CommandSubmitter
        func makeCommandBuffer() throws -> MTLCommandBuffer { try inner.makeCommandBuffer() }
        func commitAndWait(_ buffer: MTLCommandBuffer) -> CommandCompletion {
            // Commit+wait the real buffer (so encoding is valid), then force the failed mapping.
            _ = inner.commitAndWait(buffer)
            return .failed(status: "error", detail: "injected deterministic failure")
        }
    }

    /// A submitter whose commit blocks on a signal — used to prove the non-blocking execution guard.
    final class BlockingSubmitter: CommandSubmitter, @unchecked Sendable {
        let inner: CommandSubmitter
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        init(_ inner: CommandSubmitter) { self.inner = inner }
        func makeCommandBuffer() throws -> MTLCommandBuffer { try inner.makeCommandBuffer() }
        func commitAndWait(_ buffer: MTLCommandBuffer) -> CommandCompletion {
            entered.signal()
            release.wait()
            return inner.commitAndWait(buffer)
        }
    }

    private func makeSession(_ device: MTLDevice, submitter: CommandSubmitter? = nil) throws -> MetalRenderSession {
        if let submitter {
            return try MetalRenderSession(device: device, shaderLoader: RuntimeSourceShaderLoader(), submitter: submitter)
        }
        return try MetalRenderSession(device: device)
    }

    private func realSubmitter(_ device: MTLDevice) throws -> RealCommandSubmitter {
        guard let queue = device.makeCommandQueue() else {
            throw XCTSkip("no command queue")
        }
        return RealCommandSubmitter(queue: queue)
    }

    // MARK: - #19 command-buffer failure via the stub, no frame

    func testCommandBufferFailureSurfacesTyped() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let session = try makeSession(device, submitter: StubFailingSubmitter(inner: try realSubmitter(device)))
        let graph = try MetalTestEnvironment.clearOnlyGraph(width: 4, height: 4, profile: .rgba16FloatLinear)
        XCTAssertThrowsError(try session.execute(graph)) { error in
            guard case MetalRenderError.commandBufferFailed = error else {
                return XCTFail("expected commandBufferFailed, got \(error)")
            }
        }
    }

    // MARK: - #20 no partial frame on failure

    func testNoPartialFrameOnFailure() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let session = try makeSession(device, submitter: StubFailingSubmitter(inner: try realSubmitter(device)))
        let graph = try MetalTestEnvironment.clearOnlyGraph(width: 4, height: 4, profile: .bgra8SRGB)
        var produced: RenderedFrame?
        do { produced = try session.execute(graph) } catch { produced = nil }
        XCTAssertNil(produced, "no frame may be returned on a failed command buffer")
    }

    // MARK: - C-15/C-16 engine-owned references released after success AND failure (deinit observer)

    /// Proves the engine releases the per-execution `MetalResourceOwner` (and everything it strongly
    /// retains) after `execute()` returns. Uses the owner `deinit` observer (C3) and a weak reference —
    /// NOT re-execution. Makes NO claim about driver-internal MTLTexture/MTLBuffer destruction (§7).
    private func assertOwnerReleased(injectFailure: Bool) throws {
        let device = try MetalTestEnvironment.requireDevice()
        let submitter: CommandSubmitter = injectFailure
            ? StubFailingSubmitter(inner: try realSubmitter(device))
            : try realSubmitter(device)
        let session = try makeSession(device, submitter: submitter)

        // A graph with a pixel resource (so raw + normalized textures + staging are owned).
        let img = try MetalTestEnvironment.makePixelInput(
            id: "lifecycle", width: 2, height: 2,
            straightBGRA: Array(repeating: (b: 0, g: 0, r: 255, a: 255), count: 4))
        let graph = try MetalTestEnvironment.singleImageGraph(
            width: 2, height: 2, profile: .rgba16FloatLinear, pixels: img)

        weak var weakOwner: MetalResourceOwner?
        let deinitFired = expectation(description: "owner deinit fired")
        session.onOwnerCreated = { owner in
            weakOwner = owner
            owner.onDeinit = { deinitFired.fulfill() }
        }

        if injectFailure {
            // StubFailingSubmitter maps the completion to a deterministic failure → commandBufferFailed.
            XCTAssertThrowsError(try session.execute(graph)) { error in
                guard case MetalRenderError.commandBufferFailed = error else {
                    return XCTFail("expected commandBufferFailed, got \(error)")
                }
            }
        } else {
            _ = try session.execute(graph)
        }
        // After execute() returns, the engine's strong reference to the owner is gone.
        wait(for: [deinitFired], timeout: 5)
        XCTAssertNil(weakOwner, "engine-owned MetalResourceOwner must be released after execute()")
    }

    func testEngineOwnedResourcesReleasedAfterSuccess() throws {
        try assertOwnerReleased(injectFailure: false)
    }

    func testEngineOwnedResourcesReleasedAfterFailure() throws {
        try assertOwnerReleased(injectFailure: true)
    }

    // MARK: - Classifier: ALL categories supported after Step 12 (cut/fade/slide/overlay execute)

    func testAllCommandCategoriesClassifySupportedAfterStep12() throws {
        // After Step 12, NO command category is deferred — the classifier returns nil for every category.
        let mesh = try SampledPathMesh(
            pathID: 0,
            positions: [CanvasScalar(rawValue: 0), CanvasScalar(rawValue: 0),
                        CanvasScalar(rawValue: 65536), CanvasScalar(rawValue: 0),
                        CanvasScalar(rawValue: 65536), CanvasScalar(rawValue: 65536)],
            indices: [0, 1, 2], closed: true)
        let maskOp = SampledMaskOperation(mode: .add, inverted: false, opacity: .opaque, mesh: mesh, pathToTarget: .identity)
        let shape = try SampledShape(
            fillMesh: mesh, fillColor: try SampledSRGBAColor(components: [.one, .zero, .zero, .one]),
            fillOpacity: .opaque, stroke: nil, groupOpacity: .opaque)
        let allPayloads: [RenderCommandPayload] = [
            // Step-12 (now supported):
            .fadeTransition(easedProgress: .zero, outgoingSurfaceID: "o", incomingSurfaceID: "i", targetSurfaceID: "t"),
            .slideTransition(direction: .left, easedProgress: .zero, offsetX: 0, offsetY: 0,
                             outgoingSurfaceID: "o", incomingSurfaceID: "i", targetSurfaceID: "t"),
            .overlay(resourceID: "r", transform: .identity, opacity: .opaque, compositionOrder: 0, targetSurfaceID: "t"),
            // Step-11:
            .drawShape(shape: shape, transform: .identity, opacity: .opaque, targetSurfaceID: "t"),
            .beginMask(operations: [maskOp], contentSurfaceID: "content", targetSurfaceID: "t"),
            .endMask(contentSurfaceID: "content", targetSurfaceID: "t"),
            .matteLink(mode: .alpha, sourceLayerID: 1, consumerLayerID: 2, sourceSurfaceID: "src", consumerSurfaceID: "con", targetSurfaceID: "t"),
            // Step-10:
            .clearBackground(color: .transparentBlack, targetSurfaceID: "t"),
            .beginScene(sceneID: "s", role: .sole, targetSurfaceID: "t"),
            .endScene(sceneID: "s", role: .sole, targetSurfaceID: "t"),
            .drawImage(resourceID: "r", transform: .identity, opacity: .opaque, targetSurfaceID: "t"),
            .drawVideoFrame(resourceID: "r", transform: .identity, opacity: .opaque, targetSurfaceID: "t"),
            .beginClip(rect: try FixedRect(x: .init(rawValue: 0), y: .init(rawValue: 0),
                                           width: .init(rawValue: 1), height: .init(rawValue: 1))),
            .endClip,
            .finalLinearToSRGB(sourceSurfaceID: "a", targetSurfaceID: "b"),
            .finalOutput(sourceSurfaceID: "b"),
        ]
        for p in allPayloads {
            XCTAssertNil(MetalSceneCompositor.unsupportedCommand(for: p), "\(p.category) must be supported after Step 12")
        }
    }

    // MARK: - After Step 12 there are NO reachable deferred families (every category executes)

    func testNoReachableDeferredFamiliesAfterStep12() throws {
        // The fade/slide/overlay graphs that earlier steps REJECTED now EXECUTE without an
        // unsupportedCommand error. (Pixel correctness is proven in TransitionOverlayTests.)
        let device = try MetalTestEnvironment.requireDevice()
        let session = try makeSession(device)
        let w: Int64 = 4, h: Int64 = 4

        // Build a validator-valid graph from a body builder. Must CONSTRUCT (the test fails if
        // construction throws — never accepts construction-failure as executor evidence).
        func graph(_ body: (_ add: (RenderCommandPayload) throws -> Void) throws -> Void) throws -> RenderGraph {
            let config = try MetalTestEnvironment.configuration(width: w, height: h, profile: .rgba16FloatLinear)
            var cmds: [RenderCommand] = []
            var o = 0
            func add(_ p: RenderCommandPayload) throws { cmds.append(try RenderCommand(ordinal: o, payload: p)); o += 1 }
            try add(.offscreenSurface(MetalTestEnvironment.linearCanvasDescriptor(width: w, height: h, profile: .rgba16FloatLinear)))
            try add(.offscreenSurface(MetalTestEnvironment.sRGBSurfaceDescriptor(width: w, height: h)))
            try add(.clearBackground(color: .transparentBlack, targetSurfaceID: RenderSurface.linearCanvas))
            try body(add)
            try add(.finalLinearToSRGB(sourceSurfaceID: RenderSurface.linearCanvas, targetSurfaceID: RenderSurface.sRGBSurface))
            try add(.finalOutput(sourceSurfaceID: RenderSurface.sRGBSurface))
            return try RenderGraph(configuration: config, commands: cmds)
        }

        // A 1x1 pixel input used to mark surfaces "drawn into"/"written" so matte/transition graphs are
        // validator-valid. Declared once at the top of each graph that needs it.
        let px = try MetalTestEnvironment.makePixelInput(
            id: "px", width: 4, height: 4,
            straightBGRA: Array(repeating: (b: 0, g: 0, r: 255, a: 255), count: 16))
        let pxDecl = RenderCommandPayload.declareResource(
            RenderResourceDescriptor(pixelInputID: "px", pixels: px, colorContract: .task003))
        func sceneSurface(_ id: String) -> RenderCommandPayload {
            .offscreenSurface(RenderResourceDescriptor(
                offscreenID: id, width: MetalTestEnvironment.canvasRaw(w), height: MetalTestEnvironment.canvasRaw(h),
                profile: .intermediate(.rgba16FloatLinear), colorContract: .task003))
        }

        // Each family is a validator-valid graph that the executor now EXECUTES (Step 12) without an
        // unsupportedCommand error — formerly the three deferred families.
        let families: [(name: String, build: () throws -> RenderGraph)] = [
            ("fadeTransition", { try Self.transitionGraph(w: w, h: h, slide: false, pxDecl: pxDecl, sceneSurface: sceneSurface) }),
            ("slideTransition", { try Self.transitionGraph(w: w, h: h, slide: true, pxDecl: pxDecl, sceneSurface: sceneSurface) }),
            ("overlay", {
                let overlayPixels = try MetalTestEnvironment.makePixelInput(
                    id: "r", width: 1, height: 1, straightBGRA: [(b: 0, g: 0, r: 255, a: 255)])
                let config = try MetalTestEnvironment.configuration(width: w, height: h, profile: .rgba16FloatLinear)
                var cmds: [RenderCommand] = []
                var o = 0
                func add(_ p: RenderCommandPayload) throws { cmds.append(try RenderCommand(ordinal: o, payload: p)); o += 1 }
                try add(.declareResource(RenderResourceDescriptor(pixelInputID: "r", pixels: overlayPixels, colorContract: .task003)))
                try add(.offscreenSurface(MetalTestEnvironment.linearCanvasDescriptor(width: w, height: h, profile: .rgba16FloatLinear)))
                try add(.offscreenSurface(MetalTestEnvironment.sRGBSurfaceDescriptor(width: w, height: h)))
                try add(.clearBackground(color: .transparentBlack, targetSurfaceID: RenderSurface.linearCanvas))
                try add(.overlay(resourceID: "r", transform: .identity, opacity: .opaque, compositionOrder: 0, targetSurfaceID: RenderSurface.linearCanvas))
                try add(.finalLinearToSRGB(sourceSurfaceID: RenderSurface.linearCanvas, targetSurfaceID: RenderSurface.sRGBSurface))
                try add(.finalOutput(sourceSurfaceID: RenderSurface.sRGBSurface))
                return try RenderGraph(configuration: config, commands: cmds)
            }),
        ]
        XCTAssertEqual(families.count, 3, "fade/slide/overlay must all execute after Step 12")
        for fam in families {
            let g: RenderGraph
            do { g = try fam.build() } catch {
                return XCTFail("\(fam.name): graph construction must succeed, got \(error)")
            }
            // Must NOT throw unsupportedCommand; it executes and returns a frame.
            XCTAssertNoThrow(try session.execute(g), "\(fam.name) must execute (not be rejected) after Step 12")
        }
    }

    /// A validator-valid fade/slide transition graph: two scene surfaces each DRAWN INTO (so they are
    /// "written"), then the transition composites them into the linear canvas. After Step 12 the executor
    /// EXECUTES this graph.
    private static func transitionGraph(
        w: Int64, h: Int64, slide: Bool,
        pxDecl: RenderCommandPayload,
        sceneSurface: (String) -> RenderCommandPayload
    ) throws -> RenderGraph {
        let outgoing = "scene\u{1F}out", incoming = "scene\u{1F}in"
        let config = try MetalTestEnvironment.configuration(width: w, height: h, profile: .rgba16FloatLinear)
        var cmds: [RenderCommand] = []
        var o = 0
        func add(_ p: RenderCommandPayload) throws { cmds.append(try RenderCommand(ordinal: o, payload: p)); o += 1 }
        try add(pxDecl)
        try add(.offscreenSurface(MetalTestEnvironment.linearCanvasDescriptor(width: w, height: h, profile: .rgba16FloatLinear)))
        try add(.offscreenSurface(MetalTestEnvironment.sRGBSurfaceDescriptor(width: w, height: h)))
        try add(sceneSurface(outgoing))
        try add(sceneSurface(incoming))
        try add(.clearBackground(color: .transparentBlack, targetSurfaceID: RenderSurface.linearCanvas))
        // Write the outgoing scene surface via a draw.
        try add(.clearBackground(color: .transparentBlack, targetSurfaceID: outgoing))
        try add(.beginScene(sceneID: "o", role: .outgoing, targetSurfaceID: outgoing))
        try add(.drawImage(resourceID: "px", transform: .identity, opacity: .opaque, targetSurfaceID: outgoing))
        try add(.endScene(sceneID: "o", role: .outgoing, targetSurfaceID: outgoing))
        // Write the incoming scene surface via a draw.
        try add(.clearBackground(color: .transparentBlack, targetSurfaceID: incoming))
        try add(.beginScene(sceneID: "i", role: .incoming, targetSurfaceID: incoming))
        try add(.drawImage(resourceID: "px", transform: .identity, opacity: .opaque, targetSurfaceID: incoming))
        try add(.endScene(sceneID: "i", role: .incoming, targetSurfaceID: incoming))
        if slide {
            try add(.slideTransition(direction: .left, easedProgress: .zero, offsetX: 0, offsetY: 0,
                                     outgoingSurfaceID: outgoing, incomingSurfaceID: incoming, targetSurfaceID: RenderSurface.linearCanvas))
        } else {
            try add(.fadeTransition(easedProgress: .zero, outgoingSurfaceID: outgoing, incomingSurfaceID: incoming,
                                    targetSurfaceID: RenderSurface.linearCanvas))
        }
        try add(.finalLinearToSRGB(sourceSurfaceID: RenderSurface.linearCanvas, targetSurfaceID: RenderSurface.sRGBSurface))
        try add(.finalOutput(sourceSurfaceID: RenderSurface.sRGBSurface))
        return try RenderGraph(configuration: config, commands: cmds)
    }

    // MARK: - #16b non-transparent clear fails closed (preflight)

    func testNonTransparentClearThrows() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let session = try makeSession(device)
        let w: Int64 = 4, h: Int64 = 4
        let config = try MetalTestEnvironment.configuration(width: w, height: h, profile: .rgba16FloatLinear)
        let red = try PremultipliedColor(red: .one, green: .zero, blue: .zero, alpha: .one)
        var cmds: [RenderCommand] = []
        var o = 0
        func add(_ p: RenderCommandPayload) throws { cmds.append(try RenderCommand(ordinal: o, payload: p)); o += 1 }
        try add(.offscreenSurface(MetalTestEnvironment.linearCanvasDescriptor(width: w, height: h, profile: .rgba16FloatLinear)))
        try add(.offscreenSurface(MetalTestEnvironment.sRGBSurfaceDescriptor(width: w, height: h)))
        try add(.clearBackground(color: red, targetSurfaceID: RenderSurface.linearCanvas))
        try add(.finalLinearToSRGB(sourceSurfaceID: RenderSurface.linearCanvas, targetSurfaceID: RenderSurface.sRGBSurface))
        try add(.finalOutput(sourceSurfaceID: RenderSurface.sRGBSurface))
        let graph = try RenderGraph(configuration: config, commands: cmds)
        XCTAssertThrowsError(try session.execute(graph)) { error in
            guard case MetalRenderError.unsupportedClearColor = error else {
                return XCTFail("expected unsupportedClearColor, got \(error)")
            }
        }
    }

    // MARK: - #25 framesInFlight != 1 rejected

    func testFramesInFlightMustBeOne() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let session = try makeSession(device)
        let canvas = try CanvasSize(width: 4, height: 4)
        let output = OutputContext(canvas: canvas, frameRate: try FrameRate(numerator: 30, denominator: 1))
        let config = try RenderConfiguration(output: output, intermediateProfile: .rgba16FloatLinear, framesInFlight: 2)
        var cmds: [RenderCommand] = []
        var o = 0
        func add(_ p: RenderCommandPayload) throws { cmds.append(try RenderCommand(ordinal: o, payload: p)); o += 1 }
        try add(.offscreenSurface(RenderResourceDescriptor(
            offscreenID: RenderSurface.linearCanvas, width: MetalTestEnvironment.canvasRaw(4), height: MetalTestEnvironment.canvasRaw(4),
            profile: .intermediate(.rgba16FloatLinear), colorContract: .task003)))
        try add(.offscreenSurface(RenderResourceDescriptor(
            offscreenID: RenderSurface.sRGBSurface, width: MetalTestEnvironment.canvasRaw(4), height: MetalTestEnvironment.canvasRaw(4),
            profile: .finalSRGB, colorContract: .task003)))
        try add(.clearBackground(color: .transparentBlack, targetSurfaceID: RenderSurface.linearCanvas))
        try add(.finalLinearToSRGB(sourceSurfaceID: RenderSurface.linearCanvas, targetSurfaceID: RenderSurface.sRGBSurface))
        try add(.finalOutput(sourceSurfaceID: RenderSurface.sRGBSurface))
        let graph = try RenderGraph(configuration: config, commands: cmds)
        XCTAssertThrowsError(try session.execute(graph)) { error in
            guard case MetalRenderError.unsupportedFramesInFlight(let v) = error else {
                return XCTFail("expected unsupportedFramesInFlight, got \(error)")
            }
            XCTAssertEqual(v, 2)
        }
    }

    // MARK: - C-13a undeclared resource via public execute() → exact RenderGraphError (honest path)

    func testUndeclaredResourceIsRenderGraphError() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let session = try makeSession(device)
        // A structurally valid-looking graph whose draw references an undeclared resource. The
        // RenderGraphValidator (run first in preflight) rejects it as a RenderGraphError — NOT a
        // MetalRenderError. A structurally valid public graph never reaches MetalRenderError.missingResource.
        let w: Int64 = 4, h: Int64 = 4
        let config = try MetalTestEnvironment.configuration(width: w, height: h, profile: .rgba16FloatLinear)
        var cmds: [RenderCommand] = []
        var o = 0
        func add(_ p: RenderCommandPayload) throws { cmds.append(try RenderCommand(ordinal: o, payload: p)); o += 1 }
        try add(.offscreenSurface(MetalTestEnvironment.linearCanvasDescriptor(width: w, height: h, profile: .rgba16FloatLinear)))
        try add(.offscreenSurface(MetalTestEnvironment.sRGBSurfaceDescriptor(width: w, height: h)))
        try add(.clearBackground(color: .transparentBlack, targetSurfaceID: RenderSurface.linearCanvas))
        try add(.beginScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas))
        try add(.drawImage(resourceID: "absent", transform: .identity, opacity: .opaque, targetSurfaceID: RenderSurface.linearCanvas))
        try add(.endScene(sceneID: "s", role: .sole, targetSurfaceID: RenderSurface.linearCanvas))
        try add(.finalLinearToSRGB(sourceSurfaceID: RenderSurface.linearCanvas, targetSurfaceID: RenderSurface.sRGBSurface))
        try add(.finalOutput(sourceSurfaceID: RenderSurface.sRGBSurface))
        // The graph either fails to construct (validator at init) or at execute() preflight — in BOTH cases
        // the exact case is RenderGraphError.validatorMissingResource(resourceID: "absent"), never a
        // MetalRenderError and never any other RenderGraphError.
        func assertMissingResource(_ error: Error) {
            guard case let RenderGraphError.validatorMissingResource(resourceID) = error else {
                return XCTFail("expected validatorMissingResource, got \(error)")
            }
            XCTAssertEqual(resourceID, "absent")
        }
        do {
            let graph = try RenderGraph(configuration: config, commands: cmds)
            // Constructed: the executor preflight's validator pass rejects it.
            XCTAssertThrowsError(try session.execute(graph)) { assertMissingResource($0) }
        } catch {
            // Construction itself rejected it (the graph validator runs at init in some configurations).
            assertMissingResource(error)
        }
    }

    // MARK: - C-13b MetalRenderError.missingResource is an EXECUTION BACKSTOP, tested via the owner seam

    func testMissingResourceBackstopViaSeam() throws {
        // An empty owner has no registered resources; the lookup is the executor's internal backstop that a
        // structurally valid public graph cannot reach. Assert the exact typed error + id.
        let owner = MetalResourceOwner()
        XCTAssertThrowsError(try owner.normalizedTexture(for: "never-registered")) { error in
            guard case let MetalRenderError.missingResource(id) = error else {
                return XCTFail("expected missingResource, got \(error)")
            }
            XCTAssertEqual(id, "never-registered")
        }
        XCTAssertThrowsError(try owner.surface(for: "no-surface")) { error in
            guard case let MetalRenderError.missingResource(id) = error else {
                return XCTFail("expected missingResource, got \(error)")
            }
            XCTAssertEqual(id, "no-surface")
        }
    }

    // MARK: - #18 missing shader function typed error

    func testMissingShaderFunctionTyped() throws {
        let device = try MetalTestEnvironment.requireDevice()
        struct EmptyLoader: ShaderLibraryLoader {
            func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
                // A library with no functions: makeFunction returns nil → missingShaderFunction.
                try device.makeLibrary(source: "#include <metal_stdlib>\nusing namespace metal;\n", options: nil)
            }
        }
        guard let queue = device.makeCommandQueue() else { throw XCTSkip("no queue") }
        XCTAssertThrowsError(
            try MetalRenderSession(device: device, shaderLoader: EmptyLoader(), submitter: RealCommandSubmitter(queue: queue))
        ) { error in
            guard case MetalRenderError.missingShaderFunction = error else {
                return XCTFail("expected missingShaderFunction, got \(error)")
            }
        }
    }

    // MARK: - #27 concurrent/reentrant execute() rejected (R3)

    func testExecutionAlreadyInProgress() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let blocking = BlockingSubmitter(try realSubmitter(device))
        let session = try makeSession(device, submitter: blocking)
        let graph = try MetalTestEnvironment.clearOnlyGraph(width: 4, height: 4, profile: .rgba16FloatLinear)

        let firstDone = expectation(description: "first execute completes")
        DispatchQueue.global().async {
            _ = try? session.execute(graph)
            firstDone.fulfill()
        }
        // Wait until the first execute is inside commitAndWait (holding the guard).
        XCTAssertEqual(blocking.entered.wait(timeout: .now() + 5), .success)
        // A second concurrent execute must be rejected immediately, no block/deadlock.
        XCTAssertThrowsError(try session.execute(graph)) { error in
            guard case MetalRenderError.executionAlreadyInProgress = error else {
                return XCTFail("expected executionAlreadyInProgress, got \(error)")
            }
        }
        // Release the first execute and let it finish.
        blocking.release.signal()
        wait(for: [firstDone], timeout: 5)
    }

    // MARK: - #9 padded source bytesPerRow upload (opaque, exact)

    func testPaddedBytesPerRowUpload() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let session = try makeSession(device)
        // 2x1 opaque image with a padded stride (8 active bytes + 8 padding).
        let pixels = try MetalTestEnvironment.makePixelInput(
            id: "padded", width: 2, height: 1, bytesPerRow: 16,
            straightBGRA: [(b: 0, g: 0, r: 255, a: 255), (b: 255, g: 0, r: 0, a: 255)])
        let graph = try MetalTestEnvironment.singleImageGraph(
            width: 2, height: 1, profile: .rgba16FloatLinear, pixels: pixels)
        let frame = try session.execute(graph)
        // Pixel (0,0) is red, (1,0) is blue (physical BGRA).
        let p0 = MetalTestEnvironment.pixel(frame, x: 0, y: 0)
        let p1 = MetalTestEnvironment.pixel(frame, x: 1, y: 0)
        XCTAssertEqual(p0.r, 255); XCTAssertEqual(p0.b, 0); XCTAssertEqual(p0.a, 255)
        XCTAssertEqual(p1.b, 255); XCTAssertEqual(p1.r, 0); XCTAssertEqual(p1.a, 255)
    }

    // MARK: - #9b odd-width upload + aligned staging

    func testOddWidthUploadAndReadback() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let session = try makeSession(device)
        // 3x1 opaque image (odd width). Stride is tight (12) — readback uses 256-aligned staging then tight repack.
        let pixels = try MetalTestEnvironment.makePixelInput(
            id: "odd", width: 3, height: 1,
            straightBGRA: [(b: 0, g: 0, r: 255, a: 255), (b: 0, g: 255, r: 0, a: 255), (b: 255, g: 0, r: 0, a: 255)])
        let graph = try MetalTestEnvironment.singleImageGraph(
            width: 3, height: 1, profile: .rgba16FloatLinear, pixels: pixels)
        let frame = try session.execute(graph)
        XCTAssertEqual(frame.dimensions.width, 3)
        XCTAssertEqual(frame.dimensions.bytesPerRow, 12)  // tight output
        let p0 = MetalTestEnvironment.pixel(frame, x: 0, y: 0)
        let p1 = MetalTestEnvironment.pixel(frame, x: 1, y: 0)
        let p2 = MetalTestEnvironment.pixel(frame, x: 2, y: 0)
        XCTAssertEqual(p0.r, 255)
        XCTAssertEqual(p1.g, 255)
        XCTAssertEqual(p2.b, 255)
    }

    // MARK: - #14b ceilDiv Int64 boundaries (no Int64.min negation)

    func testClipCeilDivInt64Boundaries() throws {
        // Reference ceiling using Double is not exact at Int64.min; assert the algebraic identity instead:
        // for b > 0, ceilDiv(a,b) is the unique q with (q-1)*b < a <= q*b. We verify q*b >= a and
        // (q-1)*b < a using checked arithmetic, and that Int64.min does not trap.
        let bs: [Int64] = [1, 2, 65_536, 3]
        let as_: [Int64] = [.min, .min + 1, -65_537, -1, 0, 1, 65_535, 65_536, .max - 1, .max]
        for b in bs {
            for a in as_ {
                let q = try MetalSceneCompositor.ceilDiv(a, b)
                // q*b >= a  (q is an upper ceiling)
                if let qb = try? CheckedInt64.multiply(q, b, "test.qb") {
                    XCTAssertGreaterThanOrEqual(qb, a, "ceilDiv(\(a),\(b))=\(q): q*b < a")
                    // (q-1)*b < a
                    if let qm1 = try? CheckedInt64.subtract(q, 1, "test.q-1"),
                       let qm1b = try? CheckedInt64.multiply(qm1, b, "test.qm1b") {
                        XCTAssertLessThan(qm1b, a, "ceilDiv(\(a),\(b))=\(q): (q-1)*b >= a")
                    }
                }
            }
        }
        // Non-positive divisor is a typed failure (geometryOverflow), never a trap.
        XCTAssertThrowsError(try MetalSceneCompositor.ceilDiv(5, 0)) { error in
            guard case MetalRenderError.geometryOverflow = error else { return XCTFail("got \(error)") }
        }
        XCTAssertThrowsError(try MetalSceneCompositor.ceilDiv(5, -1)) { error in
            guard case MetalRenderError.geometryOverflow = error else { return XCTFail("got \(error)") }
        }
    }

    // MARK: - C-7a/b roundUp + stride arithmetic overflow → typed throw (no trap)

    func testRoundUpOverflowThrows() {
        // value near Int.max so rounding up to 256 overflows → typed throw, not a trap.
        XCTAssertThrowsError(
            try MetalResourceUploader.roundUp(Int.max - 3, to: 256,
                MetalRenderError.uploadFailed(resourceID: "x", detail: "overflow"))
        ) { error in
            guard case MetalRenderError.uploadFailed = error else { return XCTFail("got \(error)") }
        }
        // A normal value rounds up correctly.
        XCTAssertEqual(try MetalResourceUploader.roundUp(12, to: 256, .uploadFailed(resourceID: "x", detail: "n")), 256)
        XCTAssertEqual(try MetalResourceUploader.roundUp(256, to: 256, .uploadFailed(resourceID: "x", detail: "n")), 256)
    }

    func testStrideArithmeticChecked() {
        // CheckedInt.mul/add throw on overflow rather than trapping.
        XCTAssertThrowsError(try CheckedInt.mul(Int.max, 2, .readbackFailed(detail: "mul"))) { error in
            guard case MetalRenderError.readbackFailed = error else { return XCTFail("got \(error)") }
        }
        XCTAssertThrowsError(try CheckedInt.add(Int.max, 1, .readbackFailed(detail: "add"))) { error in
            guard case MetalRenderError.readbackFailed = error else { return XCTFail("got \(error)") }
        }
        XCTAssertEqual(try CheckedInt.mul(100, 4, .readbackFailed(detail: "ok")), 400)
        XCTAssertEqual(try CheckedInt.add(100, 4, .readbackFailed(detail: "ok")), 104)
    }

    // MARK: - C-7c clip intersection arithmetic overflow → typed throw (no trap)

    func testClipIntersectionArithmeticChecked() {
        let huge = MetalSceneCompositor.ScissorBounds(x: Int.max - 1, y: 0, width: Int.max, height: 1, isEmpty: false)
        let other = MetalSceneCompositor.ScissorBounds(x: 0, y: 0, width: Int.max, height: Int.max, isEmpty: false)
        XCTAssertThrowsError(try MetalSceneCompositor.intersect(huge, other)) { error in
            guard case MetalRenderError.geometryOverflow = error else { return XCTFail("got \(error)") }
        }
        // A normal intersection succeeds.
        let a = MetalSceneCompositor.ScissorBounds(x: 0, y: 0, width: 4, height: 4, isEmpty: false)
        let b = MetalSceneCompositor.ScissorBounds(x: 2, y: 2, width: 4, height: 4, isEmpty: false)
        let r = try? MetalSceneCompositor.intersect(a, b)
        XCTAssertEqual(r, MetalSceneCompositor.ScissorBounds(x: 2, y: 2, width: 2, height: 2, isEmpty: false))
    }

    // MARK: - C-8/C-9/C-10 surface-dimension preflight (Issue 4) — EXACT surfaceDimensionMismatch via seam

    /// Build a graph whose surfaces are sized as given. The structural validator only checks positivity of
    /// surface dims (not equality to the canvas), so such a graph is validator-VALID; the executor's own
    /// geometry preflight (`metalPreflight`) is what must reject it with `surfaceDimensionMismatch`. We test
    /// that seam directly so the assertion is the EXACT MetalRenderError, never a RenderGraphError or a
    /// graph-construction failure (corrective Rev-4 pt.3).
    private func geometryGraph(
        linearW: Int64, linearH: Int64, srgbW: Int64, srgbH: Int64,
        configW: Int64, configH: Int64,
        sceneTarget: (id: String, w: Int64, h: Int64)? = nil
    ) throws -> (RenderGraph, RenderConfiguration) {
        let config = try MetalTestEnvironment.configuration(width: configW, height: configH, profile: .rgba16FloatLinear)
        var cmds: [RenderCommand] = []
        var o = 0
        func add(_ p: RenderCommandPayload) throws { cmds.append(try RenderCommand(ordinal: o, payload: p)); o += 1 }
        try add(.offscreenSurface(RenderResourceDescriptor(
            offscreenID: RenderSurface.linearCanvas,
            width: MetalTestEnvironment.canvasRaw(linearW), height: MetalTestEnvironment.canvasRaw(linearH),
            profile: .intermediate(.rgba16FloatLinear), colorContract: .task003)))
        try add(.offscreenSurface(RenderResourceDescriptor(
            offscreenID: RenderSurface.sRGBSurface,
            width: MetalTestEnvironment.canvasRaw(srgbW), height: MetalTestEnvironment.canvasRaw(srgbH),
            profile: .finalSRGB, colorContract: .task003)))
        if let st = sceneTarget {
            try add(.offscreenSurface(RenderResourceDescriptor(
                offscreenID: st.id,
                width: MetalTestEnvironment.canvasRaw(st.w), height: MetalTestEnvironment.canvasRaw(st.h),
                profile: .intermediate(.rgba16FloatLinear), colorContract: .task003)))
        }
        try add(.clearBackground(color: .transparentBlack, targetSurfaceID: RenderSurface.linearCanvas))
        if let st = sceneTarget {
            try add(.beginScene(sceneID: "s", role: .sole, targetSurfaceID: st.id))
            try add(.endScene(sceneID: "s", role: .sole, targetSurfaceID: st.id))
        }
        try add(.finalLinearToSRGB(sourceSurfaceID: RenderSurface.linearCanvas, targetSurfaceID: RenderSurface.sRGBSurface))
        try add(.finalOutput(sourceSurfaceID: RenderSurface.sRGBSurface))
        // NOTE: a sceneTarget graph may not be validator-VALID (the scene draws nothing into the canvas);
        // we still drive metalPreflight directly so the assertion is the executor's exact geometry error.
        let graph = try RenderGraph(configuration: config, commands: cmds)
        return (graph, config)
    }

    private func assertSurfaceMismatch(
        _ graph: RenderGraph, _ config: RenderConfiguration,
        resourceID: String, expectedW: Int64, expectedH: Int64, actualW: Int64, actualH: Int64
    ) {
        XCTAssertThrowsError(try MetalGraphExecutor.metalPreflight(graph, configuration: config)) { error in
            guard case let MetalRenderError.surfaceDimensionMismatch(id, ew, eh, aw, ah) = error else {
                return XCTFail("expected surfaceDimensionMismatch, got \(error)")
            }
            XCTAssertEqual(id, resourceID)
            XCTAssertEqual(ew, expectedW); XCTAssertEqual(eh, expectedH)
            XCTAssertEqual(aw, actualW);   XCTAssertEqual(ah, actualH)
        }
    }

    // C-8: linearCanvas 5x4 ≠ configuration canvas 4x4 → exact surfaceDimensionMismatch.
    func testLinearCanvasMustMatchConfigurationCanvas() throws {
        let (g, c) = try geometryGraph(linearW: 5, linearH: 4, srgbW: 4, srgbH: 4, configW: 4, configH: 4)
        assertSurfaceMismatch(g, c, resourceID: RenderSurface.linearCanvas,
                              expectedW: 4, expectedH: 4, actualW: 5, actualH: 4)
    }

    // C-9: sRGB surface 4x5 ≠ linearCanvas/canvas 4x4 → exact surfaceDimensionMismatch.
    func testFinalSRGBMustMatchLinearCanvas() throws {
        let (g, c) = try geometryGraph(linearW: 4, linearH: 4, srgbW: 4, srgbH: 5, configW: 4, configH: 4)
        assertSurfaceMismatch(g, c, resourceID: RenderSurface.sRGBSurface,
                              expectedW: 4, expectedH: 4, actualW: 4, actualH: 5)
    }

    // C-10: a scene target sized ≠ canvas → exact surfaceDimensionMismatch.
    func testSceneTargetDimensionsChecked() throws {
        let sceneID = "scene\u{1F}t"
        let (g, c) = try geometryGraph(
            linearW: 4, linearH: 4, srgbW: 4, srgbH: 4, configW: 4, configH: 4,
            sceneTarget: (id: sceneID, w: 6, h: 4))
        assertSurfaceMismatch(g, c, resourceID: sceneID,
                              expectedW: 4, expectedH: 4, actualW: 6, actualH: 4)
    }

    // MARK: - C-11 final conversion never resamples (positive control: equal dims render 1:1)

    func testFinalConversionNeverResamples() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let session = try makeSession(device)
        // Equal dims everywhere → a complete frame at the exact canvas size.
        let frame = try session.execute(try MetalTestEnvironment.clearOnlyGraph(width: 6, height: 4, profile: .rgba16FloatLinear))
        XCTAssertEqual(frame.dimensions.width, 6)
        XCTAssertEqual(frame.dimensions.height, 4)
    }

    // MARK: - C-6 target render format resolved explicitly (no default) — via the execution-event order

    // MARK: - C-17 execution-event order (Issue 7b): upload→normalize→scene→final→readback→commit→completion

    func testExecutionEventOrder() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let session = try makeSession(device)
        let img = try MetalTestEnvironment.makePixelInput(
            id: "events", width: 2, height: 2,
            straightBGRA: Array(repeating: (b: 0, g: 0, r: 255, a: 255), count: 4))
        let graph = try MetalTestEnvironment.singleImageGraph(
            width: 2, height: 2, profile: .rgba16FloatLinear, pixels: img)

        var events: [ExecutionEvent] = []
        session.onExecutionEvent = { events.append($0) }
        _ = try session.execute(graph)

        // The `uploadBlit` event only fires on the `.private` (iOS) upload path; on macOS the source is
        // host-populated (no upload blit, per the plan §8.1 / §10). Assert the order excluding uploadBlit,
        // and (where present) that uploadBlit precedes normalize.
        let nonUpload = events.filter { $0 != .uploadBlit }
        XCTAssertEqual(nonUpload, [
            .normalize(resourceID: img.id.rawValue),
            .sceneRender,
            .finalConversion,
            .readbackBlit,
            .commit,
            .completion,
        ])
        if let up = events.firstIndex(of: .uploadBlit),
           let nm = events.firstIndex(of: .normalize(resourceID: img.id.rawValue)) {
            XCTAssertLessThan(up, nm, "uploadBlit must precede normalize")
        }
        // Structural invariants: normalize before scene; readback after final; commit before completion.
        func idx(_ e: ExecutionEvent) -> Int { events.firstIndex(of: e)! }
        XCTAssertLessThan(idx(.normalize(resourceID: img.id.rawValue)), idx(.sceneRender))
        XCTAssertLessThan(idx(.finalConversion), idx(.readbackBlit))
        XCTAssertLessThan(idx(.commit), idx(.completion))
    }

    // A clear-only graph (no pixel resource) records no upload/normalize.
    func testExecutionEventOrderClearOnly() throws {
        let device = try MetalTestEnvironment.requireDevice()
        let session = try makeSession(device)
        let graph = try MetalTestEnvironment.clearOnlyGraph(width: 2, height: 2, profile: .rgba16FloatLinear)
        var events: [ExecutionEvent] = []
        session.onExecutionEvent = { events.append($0) }
        _ = try session.execute(graph)
        XCTAssertFalse(events.contains(.uploadBlit), "clear-only graph has no upload")
        XCTAssertEqual(events, [.finalConversion, .readbackBlit, .commit, .completion])
    }

    // MARK: - C-2a / C-6 draw samples the NORMALIZED texture (raw never scene-sampled)

    func testDrawSamplesNormalizedTexture() throws {
        // Structural proof via the owner: a draw resolves the NORMALIZED texture (rgba16Float), not the raw
        // (.bgra8Unorm). We register a PixelResourceTextures and assert the owner hands back `normalized`.
        let device = try MetalTestEnvironment.requireDevice()
        let alloc = MetalTextureAllocator(device: device)
        // Build raw .bgra8Unorm + normalized rgba16Float at equal dims.
        let dims = try PixelDimensions(width: 2, height: 2, bytesPerRow: 8, format: .bgra8)
        let desc = RenderResourceDescriptor(
            pixelInputID: "p",
            pixels: try ResolvedPixelInput(id: try PixelInputID("p"), dimensions: dims, bytes: Data(count: 16)),
            colorContract: .task003)
        let raw = try alloc.makePixelInputTexture(desc)
        let normalized = try alloc.makeNormalizedTexture(width: raw.width, height: raw.height, resourceID: "p")
        let owner = MetalResourceOwner()
        owner.registerPixelResource(.init(raw: raw, normalized: normalized), for: "p")
        let drawn = try owner.normalizedTexture(for: "p")
        XCTAssertEqual(drawn.pixelFormat, .rgba16Float, "scene draws must sample the normalized rgba16Float texture")
        XCTAssertEqual(raw.pixelFormat, .bgra8Unorm, "raw upload texture is bgra8Unorm (normalization input only)")
    }

    // MARK: - Shader-library loading: both loaders resolve a usable library on this (macOS) build

    /// On the macOS `swift build` pipeline the bundle ships the `AnimiEngineRender.metal` SOURCE, so both
    /// the canonical `BundledShaderLibraryLoader` (source-compile branch) and the injectable
    /// `RuntimeSourceShaderLoader` succeed and expose the required functions. (On iOS/Xcode the bundle ships
    /// a compiled `default.metallib`; `BundledShaderLibraryLoader`'s metallib branch is verified by the
    /// app-hosted device gate, not here.)
    func testBundledAndRuntimeLoadersResolveLibrary() throws {
        let device = try MetalTestEnvironment.requireDevice()
        for loader in [AnyShaderLoader(BundledShaderLibraryLoader()), AnyShaderLoader(RuntimeSourceShaderLoader())] {
            let library = try loader.makeLibrary(device: device)
            XCTAssertNotNil(library.makeFunction(name: "normalize_fragment"), "normalize_fragment must be present")
            XCTAssertNotNil(library.makeFunction(name: "image_fragment"), "image_fragment must be present")
            XCTAssertNotNil(library.makeFunction(name: "final_srgb_fragment"), "final_srgb_fragment must be present")
        }
    }

    /// Type-erasing wrapper so the loop above can hold heterogeneous `ShaderLibraryLoader`s.
    private struct AnyShaderLoader: ShaderLibraryLoader {
        let _make: (MTLDevice) throws -> MTLLibrary
        init<L: ShaderLibraryLoader>(_ loader: L) { _make = loader.makeLibrary }
        func makeLibrary(device: MTLDevice) throws -> MTLLibrary { try _make(device) }
    }
}
