import Foundation
import Metal
import AnimiEngineRenderModel
import AnimiEngineRenderGraph

/// Task-003 plan §4, §8, §10 — the sole public entry point of the Metal executor.
///
/// `MetalRenderSession.execute(_:) throws -> RenderedFrame` (plan §8). The session owns the device, one
/// command queue, and the pipeline library (built once); nothing is process-global. It is a `final class`,
/// **not `Sendable`**, and must not be treated as safely transferable across Swift concurrency domains
/// (plan §4.2, R3). An internal **non-blocking** execution guard makes a concurrent/reentrant `execute()`
/// return `MetalRenderError.executionAlreadyInProgress` immediately — no block, deadlock, or data race;
/// no `@unchecked Sendable`.
public final class MetalRenderSession {
    private let device: MTLDevice
    private let pipelines: MetalPipelineLibrary
    private let submitter: CommandSubmitter

    /// R3 non-blocking guard: a try-locked flag. Only one `execute()` may hold it at a time.
    private let guardLock = NSLock()
    private var executing = false

    /// Corrective §7b — package-internal execution-event observer; inert when nil; passed to the executor.
    /// No public API; production sets nothing, so the executor's per-milestone calls are no-ops.
    var onExecutionEvent: ((ExecutionEvent) -> Void)?
    /// Corrective §7 — package-internal hook to surface the per-execution owner to a lifecycle test.
    var onOwnerCreated: ((MetalResourceOwner) -> Void)?
    /// Diagnostic seam (package-internal, inert when nil) — forwarded to the executor; fires after each
    /// render command is encoded so a test can blit-read intermediate surface state. Production unset → no-op.
    var onCommandEncoded: ((Int, RenderCommandPayload, MetalResourceOwner, MTLCommandBuffer) -> Void)?

    /// Inject a device for tests (plan §10: "explicit MTLDevice injection for tests").
    public convenience init(device: MTLDevice) throws {
        guard let queue = device.makeCommandQueue() else {
            throw MetalRenderError.pipelineCreationFailed(detail: "command queue creation failed")
        }
        try self.init(
            device: device,
            shaderLoader: BundledShaderLibraryLoader(),
            submitter: RealCommandSubmitter(queue: queue))
    }

    /// Convenience: create from the system default device (plan §10), throwing if none exists.
    public static func makeDefault() throws -> MetalRenderSession {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalRenderError.noMetalDevice
        }
        return try MetalRenderSession(device: device)
    }

    /// Package-internal designated init: inject the shader loader and the command submitter seam
    /// (plan §10, corrections #11/#13). The public inits use the defaults.
    init(device: MTLDevice, shaderLoader: ShaderLibraryLoader, submitter: CommandSubmitter) throws {
        self.device = device
        self.submitter = submitter
        self.pipelines = try MetalPipelineLibrary(device: device, loader: shaderLoader)
    }

    /// The sole contract (plan §8). Synchronous; returns only after successful GPU completion. A
    /// concurrent/reentrant call returns `executionAlreadyInProgress` (R3) — never a data race.
    public func execute(_ graph: RenderGraph) throws -> RenderedFrame {
        guardLock.lock()
        if executing {
            guardLock.unlock()
            throw MetalRenderError.executionAlreadyInProgress
        }
        executing = true
        guardLock.unlock()

        defer {
            guardLock.lock()
            executing = false
            guardLock.unlock()
        }

        var executor = MetalGraphExecutor(
            device: device, pipelines: pipelines, submitter: submitter,
            onExecutionEvent: onExecutionEvent, onOwnerCreated: onOwnerCreated)
        executor.onCommandEncoded = onCommandEncoded
        return try executor.execute(graph)
    }
}
