import AVFoundation
import CoreVideo

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
        let alreadyCancelled = isTerminal(state)
        lock.unlock()

        if alreadyCancelled {
            pipeline.cancel()
        }
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

    /// Sets `.cancelled` flag and cancels pipeline if attached.
    /// Does NOT call cleanup or fire completion — the render loop does that via `complete(with:)`.
    func requestCancel() {
        lock.lock()
        guard !isTerminal(state) else { lock.unlock(); return }
        state = .cancelled
        let pipeline = _pipeline
        lock.unlock()

        pipeline?.cancel()
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
        MemoryDiagnostics.checkpoint("export.complete.\(outcome)")
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

        pipeline?.finishWriting { [self] result in
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
