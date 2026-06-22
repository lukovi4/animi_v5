/// Task-003 plan §4.1, §8, §9, §10 — typed error root for the stateful Metal executor.
///
/// Every failure surface of `MetalRenderSession.execute(_:)` is one of these cases (plan §10/§12). On any
/// error the executor stops, releases its per-execution resources, releases the execution guard, and
/// returns the thrown error — never a partial `RenderedFrame`, a black frame, a previous frame, or a
/// placeholder (plan §9/§12). There is no `try!`/`fatalError`/`precondition`/trap on any execution path.
public enum MetalRenderError: Error, Equatable, Sendable {
    /// No Metal device is available (`MTLCreateSystemDefaultDevice()` returned nil).
    case noMetalDevice
    /// R3 (plan §4.2): a concurrent or reentrant `execute()` was rejected by the non-blocking guard.
    case executionAlreadyInProgress
    /// Preflight (plan §4.1): `framesInFlight != 1` (Task-003 is static, one frame in flight).
    case unsupportedFramesInFlight(value: Int)
    /// The bundled Metal shader source resource could not be located (plan §9.3).
    case shaderSourceUnavailable
    /// `device.makeLibrary(source:options:)` failed to compile the shader source (plan §9.3).
    case shaderCompilationFailed(detail: String)
    /// The bundled compiled `default.metallib` could not be loaded via `makeDefaultLibrary(bundle:)`
    /// (plan §9.3 / device-gate finding): the source `.metal` was absent (Xcode compiled it to a metallib)
    /// AND loading the compiled library failed. No silent fallback — this is the explicit typed failure.
    case shaderLibraryUnavailable(detail: String)
    /// A required shader function was absent from the compiled library (plan §9.1).
    case missingShaderFunction(name: String)
    /// `device.makeRenderPipelineState(descriptor:)` failed; also the format-capability failure path (plan §6/§9.2).
    case pipelineCreationFailed(detail: String)
    /// A Step-11/12 command appeared in the graph (plan §2.2/§3.2). Rejected in preflight, before any
    /// per-execution texture, buffer, command buffer, or encoded GPU work (plan §4.1).
    case unsupportedCommand(category: String, step: Int, reason: String)
    /// A `clearBackground` colour other than premultiplied transparent black (plan §5.5, fail-closed).
    case unsupportedClearColor(detail: String)
    /// A declared surface's storage did not match the `MTLPixelFormat` expected for its role (plan §6).
    case surfaceStorageMismatch(resourceID: String, detail: String)
    /// A surface descriptor's canvas-raw dimensions did not convert exactly to a positive pixel grid,
    /// or pixel dimensions were non-positive / overflowed `Int` (plan §8.4 — positivity + exact integer only).
    case invalidSurfaceDimensions(resourceID: String, width: Int64, height: Int64)
    /// Corrective Issue 4 / §1.2a inv. 1: a surface's pixel dimensions disagreed with the dimensions the
    /// contract requires (linearCanvas ≠ configuration canvas; sRGB surface ≠ linearCanvas; scene target ≠
    /// canvas; normalized texture ≠ raw texture). Fail closed — never a silent resample.
    case surfaceDimensionMismatch(
        resourceID: String,
        expectedWidth: Int64, expectedHeight: Int64,
        actualWidth: Int64, actualHeight: Int64)
    /// A command referenced a resource id that preflight/execution found undeclared (plan §4.1 backstop).
    case missingResource(resourceID: String)
    /// `device.makeTexture(descriptor:)` / `makeBuffer(...)` returned nil — the typed capability failure
    /// (plan §6/§7.7: no hardcoded `maxTextureDim`).
    case textureAllocationFailed(resourceID: String)
    /// A pixel upload failed (allocation, checked-arithmetic overflow in stride math, etc.) (plan §8.1).
    case uploadFailed(resourceID: String, detail: String)
    /// Checked fixed-point geometry math overflowed (plan §7.7).
    case geometryOverflow(detail: String)
    /// The command buffer did not complete successfully — mapped from `CommandCompletion.failed`
    /// (plan §8.6, §13.2). No real `MTLCommandBuffer` is hand-marked failed.
    case commandBufferFailed(status: String, detail: String)
    /// The final readback produced a byte count that disagreed with the expected output (plan §8.5).
    case readbackFailed(detail: String)
    /// A complete frame could not be constructed though no earlier error was thrown (plan §8.5 backstop).
    case incompleteFrame(detail: String)
    /// Corrective C2 / §12: a render or vertex command-encoder could not be created (e.g.
    /// `makeRenderCommandEncoder`/`makeBlitCommandEncoder` returned nil), or vertex data could not be bound.
    /// Used only for encoder-creation failures; base-address guards reuse `uploadFailed`/`readbackFailed`.
    case encodingFailed(detail: String)
    /// Step-11 (Rev-4 §6.4 / §7.2): the device cannot create the required MSAA sample-count pipeline for
    /// shape/mask coverage rasterization. Fail closed — no fallback to 1× or hard edges.
    case requiredSampleCountUnsupported(sampleCount: Int)
    /// CP7.6a (`render(_:into:)`): the caller-supplied external `GPURenderTarget` texture failed
    /// validation — wrong device, pixel format ≠ `.bgra8Unorm`, missing `.renderTarget` usage, or
    /// dimensions ≠ the configuration canvas. Fail closed — never a silent resize/reinterpret.
    case invalidRenderTarget(detail: String)

    /// CP7.8 — a `dynamicTexturePixelInput` resource had no runtime texture binding, or the bound
    /// texture failed validation (wrong device / format / dimensions / usage). Fail closed: there is NO
    /// silent fallback to a placeholder or the bytes path. `detail` names the resource and the reason.
    case missingTextureBinding(resourceID: String)
    case invalidTextureBinding(resourceID: String, detail: String)
}
