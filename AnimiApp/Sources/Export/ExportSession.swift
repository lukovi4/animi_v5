import AVFoundation
import CoreVideo
import Metal

/// Owns the full export lifecycle: pre-pipeline (preparing) through post-pipeline (finishing/completed/failed/cancelled).
///
/// Created at the start of `exportVideo`/`exportTimeline` — before preload and pipeline creation.
/// Pipeline is attached later via `attachPipeline()`. Cancel can arrive at any phase.
///
/// **Threading contract:**
/// - `requestCancel()` may be called from any thread (typically UI).
/// - `complete(with:)` must be called from the render loop thread, after `videoGroup.wait()`.
/// - Cleanup closures fire inside `complete(with:)`, on the caller's thread.
/// - `completionCallback` is dispatched to main queue.
internal final class ExportSession {

    enum State {
        case preparing
        case rendering
        case finishing
        case completed(URL)
        case failed(Error)
        case cancelled
    }

    // MARK: - Private State

    private let lock = NSLock()
    private var state: State = .preparing
    private var _pipeline: ExportWriterPipeline?
    private var completionFired = false
    private let completionCallback: (Result<URL, Error>) -> Void

    // Cleanup closures — set via setCleanup() once resources are known
    private var onSuccess: (() -> Void)?
    private var onFailure: (() -> Void)?
    private var onCancel: (() -> Void)?

    // Terminal hook — fires exactly once when session reaches any terminal state
    private var onTerminal: (() -> Void)?

    // Finishing hook — fires once when finishWriting() begins (before pipeline.finishWriting)
    private var onFinishing: (() -> Void)?

    #if DEBUG
    /// Metal device stored for diagnostic checkpoint at completion.
    var diagnosticDevice: MTLDevice?
    #endif

    // MARK: - Init

    init(completion: @escaping (Result<URL, Error>) -> Void) {
        self.completionCallback = completion
    }

    // MARK: - Configuration

    func setCleanup(
        onSuccess: @escaping () -> Void,
        onFailure: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        lock.lock()
        self.onSuccess = onSuccess
        self.onFailure = onFailure
        self.onCancel = onCancel
        lock.unlock()
    }

    func setOnTerminal(_ handler: @escaping () -> Void) {
        lock.lock()
        onTerminal = handler
        lock.unlock()
    }

    func setOnFinishing(_ handler: @escaping () -> Void) {
        lock.lock()
        onFinishing = handler
        lock.unlock()
    }

    func attachPipeline(_ pipeline: ExportWriterPipeline) {
        lock.lock()
        _pipeline = pipeline
        lock.unlock()
    }

    // MARK: - State Transitions

    func transitionToRendering() {
        lock.lock()
        if case .preparing = state { state = .rendering }
        lock.unlock()
    }

    func transitionToFinishing() {
        lock.lock()
        if case .rendering = state { state = .finishing }
        lock.unlock()
    }

    // MARK: - Cancel (cooperative)

    /// Phase-aware cancel. Only performs destructive `pipeline.cancel()` during `.rendering`.
    /// In `.preparing` and `.finishing`, sets the flag only — runner-side `completeIfCancelled()`
    /// handles destructive cleanup on the export queue where it is safe.
    func requestCancel() {
        let pipelineToCancel: ExportWriterPipeline?

        lock.lock()
        guard !isTerminal(state) else { lock.unlock(); return }
        switch state {
        case .preparing:
            // startWriting() may be in progress — only set flag, no destructive cancel.
            state = .cancelled
            pipelineToCancel = nil
        case .rendering:
            // Render loop running, startWriting() completed — safe to cancel pipeline.
            state = .cancelled
            pipelineToCancel = _pipeline
        case .finishing:
            // pipeline.finishWriting() in progress — do not race with pipeline.cancel().
            state = .cancelled
            pipelineToCancel = nil
        case .completed, .failed, .cancelled:
            pipelineToCancel = nil
        }
        lock.unlock()

        pipelineToCancel?.cancel()
    }

    // MARK: - Terminal Completion

    /// The single finalization path. Called from the render loop after `videoGroup.wait()`.
    /// Fires cleanup closure, then dispatches completion to main queue.
    func complete(with result: Result<URL, Error>) {
        lock.lock()
        let wasAlreadyCancelled: Bool
        if case .cancelled = state { wasAlreadyCancelled = true } else { wasAlreadyCancelled = false }

        guard !completionFired else { lock.unlock(); return }
        completionFired = true

        let finalResult: Result<URL, Error>
        let cleanup: (() -> Void)?

        if wasAlreadyCancelled {
            finalResult = .failure(VideoExportError.cancelled)
            cleanup = onCancel
        } else {
            switch result {
            case .success(let url):
                state = .completed(url)
                cleanup = onSuccess
            case .failure(let error):
                state = .failed(error)
                cleanup = onFailure
            }
            finalResult = result
        }

        // Nil out closures to break retain cycles
        onSuccess = nil
        onFailure = nil
        onCancel = nil
        let terminalHook = onTerminal
        onTerminal = nil
        onFinishing = nil
        lock.unlock()

        cleanup?()
        terminalHook?()
        #if DEBUG
        let outcome: String
        if wasAlreadyCancelled { outcome = "cancelled" }
        else if case .failure = finalResult { outcome = "failure" }
        else { outcome = "success" }
        MemoryDiagnostics.checkpoint("export.complete.\(outcome)", metal: diagnosticDevice)
        MemoryDiagnostics.signpostEvent("export.complete")
        #endif
        DispatchQueue.main.async { [completionCallback] in completionCallback(finalResult) }
    }

    // MARK: - Queries

    /// True if cancelled or pipeline has an error. Used as the loop break condition.
    var shouldStop: Bool {
        lock.lock()
        let cancelled: Bool
        if case .cancelled = state { cancelled = true } else { cancelled = false }
        let pipeline = _pipeline
        lock.unlock()
        return cancelled || pipeline?.firstError != nil
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .cancelled = state { return true }
        return false
    }

    /// Cancellation fence.
    /// Safe before pipeline attachment from any context.
    /// If a pipeline is already attached, this must be called from the export lifecycle path
    /// that owns writer startup/cancel, normally the exportQueue runner.
    ///
    /// If cancelled:
    /// 1. Cancels the pipeline (destructive — safe because caller owns the writer lifecycle).
    /// 2. Fires `complete()` with `.cancelled` (triggers cleanup closures if registered).
    /// Returns `true` if cancelled, `false` if active.
    ///
    /// **Cleanup ordering:** call after `setCleanup()` if resources requiring cleanup exist.
    /// Calling before `setCleanup()` is safe when no resources have been created yet.
    @discardableResult
    func completeIfCancelled() -> Bool {
        let pipelineToCancel: ExportWriterPipeline?

        lock.lock()
        guard case .cancelled = state else {
            lock.unlock()
            return false
        }
        pipelineToCancel = _pipeline
        lock.unlock()

        pipelineToCancel?.cancel()
        complete(with: .failure(VideoExportError.cancelled))
        return true
    }

    /// First error from the pipeline, if any.
    var terminalError: Error? {
        lock.lock()
        let pipeline = _pipeline
        lock.unlock()
        return pipeline?.firstError
    }

    // MARK: - Progress Gating

    /// Emits progress only if session is still active (not terminal).
    func emitProgressIfActive(_ value: Double, via handler: @escaping (Double) -> Void) {
        lock.lock()
        let terminal = isTerminal(state)
        lock.unlock()
        guard !terminal else { return }
        DispatchQueue.main.async { handler(value) }
    }

    // MARK: - Pipeline Proxies

    var pixelBufferPool: CVPixelBufferPool? {
        lock.lock()
        let pipeline = _pipeline
        lock.unlock()
        return pipeline?.pixelBufferPool
    }

    func enqueueVideoFrame(
        _ pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime,
        completion: @escaping () -> Void
    ) {
        lock.lock()
        let pipeline = _pipeline
        lock.unlock()
        pipeline?.enqueueVideoFrame(pixelBuffer, presentationTime: presentationTime, completion: completion)
    }

    func setError(_ error: Error) {
        lock.lock()
        let pipeline = _pipeline
        lock.unlock()
        pipeline?.setError(error)
    }

    func startWriting() throws {
        lock.lock()
        let pipeline = _pipeline
        lock.unlock()
        try pipeline?.startWriting()
    }

    /// Transitions to finishing and calls pipeline.finishWriting, routing result through `complete(with:)`.
    func finishWriting() {
        transitionToFinishing()
        lock.lock()
        let pipeline = _pipeline
        let finishing = onFinishing
        onFinishing = nil          // fire once
        lock.unlock()

        // Emit .finishing BEFORE pipeline.finishWriting — real lifecycle phase
        finishing?()

        #if DEBUG
        let finishStartNs = DispatchTime.now().uptimeNanoseconds
        #endif

        pipeline?.finishWriting { [self] result in
            #if DEBUG
            let finishEndNs = DispatchTime.now().uptimeNanoseconds
            let elapsedSec = Double(finishEndNs - finishStartNs) / 1_000_000_000.0
            let outcome: String
            if case .success = result { outcome = "success" } else { outcome = "failure" }
            MemoryDiagnostics.event(
                "export.finishWriting.summary",
                String(format: "duration=%.2fs outcome=%@", elapsedSec, outcome)
            )
            #endif

            self.complete(with: result)
        }
    }

    // MARK: - Private

    private func isTerminal(_ state: State) -> Bool {
        switch state {
        case .completed, .failed, .cancelled: return true
        case .preparing, .rendering, .finishing: return false
        }
    }
}
