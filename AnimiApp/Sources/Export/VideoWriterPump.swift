import AVFoundation
import CoreVideo

/// Drains enqueued CVPixelBuffers into AVAssetWriterInput via requestMediaDataWhenReady.
///
/// Pump does NOT hold InFlightFrame or CVMetalTexture — only CVPixelBuffer + CMTime + completion.
/// Completion closure is called after successful append, allowing callers to signal semaphore/group.
final class VideoWriterPump {

    struct PendingFrame {
        let pixelBuffer: CVPixelBuffer
        let presentationTime: CMTime
        let completion: () -> Void
    }

    private let queue: DispatchQueue
    private let input: WriterInputScheduling
    private let adaptor: PixelBufferAppending
    private let onError: (Error) -> Void

    private let lock = NSLock()
    private var pendingFrames: [PendingFrame] = []
    private var isFinishingEnqueue = false
    private var isFinished = false
    private var finishCallback: (() -> Void)?
    private var requestCallbackRegistered = false

    init(
        input: WriterInputScheduling,
        adaptor: PixelBufferAppending,
        queue: DispatchQueue,
        onError: @escaping (Error) -> Void
    ) {
        self.input = input
        self.adaptor = adaptor
        self.queue = queue
        self.onError = onError
    }

    /// Registers requestMediaDataWhenReady callback. Call once after writer.startWriting().
    func start() {
        lock.lock()
        requestCallbackRegistered = true
        lock.unlock()

        input.requestMediaDataWhenReady(on: queue) { [weak self] in
            self?.drainPending()
        }
    }

    /// Enqueue a frame for writing. Completion is called after successful append.
    func enqueue(
        _ pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime,
        completion: @escaping () -> Void
    ) {
        let frame = PendingFrame(
            pixelBuffer: pixelBuffer,
            presentationTime: presentationTime,
            completion: completion
        )

        lock.lock()
        let finished = isFinished
        if !finished {
            pendingFrames.append(frame)
        }
        lock.unlock()

        if finished {
            // Pump already cancelled/finished — call completion to unblock caller
            completion()
            return
        }

        // Kick drain in case requestMediaDataWhenReady callback already returned
        // due to empty queue while input was ready.
        queue.async { [weak self] in
            self?.drainPending()
        }
    }

    /// Signal that no more frames will be enqueued. Completion fires after all pending
    /// frames are appended and input is marked finished.
    func finishEnqueuing(completion: @escaping () -> Void) {
        lock.lock()
        isFinishingEnqueue = true
        finishCallback = completion
        let empty = pendingFrames.isEmpty
        lock.unlock()

        if empty {
            queue.async { [weak self] in
                self?.drainPending()
            }
        }
    }

    /// Cancel the pump. Calls all pending completions to unblock callers.
    /// Does NOT call markAsFinished — writer.cancelWriting() handles cleanup.
    func cancel() {
        lock.lock()
        isFinished = true
        let frames = pendingFrames
        pendingFrames.removeAll()
        let cb = finishCallback
        finishCallback = nil
        lock.unlock()

        // Unblock all waiting callers
        for frame in frames {
            frame.completion()
        }
        cb?()
    }

    // MARK: - Private

    private func drainPending() {
        while true {
            lock.lock()
            let finished = isFinished
            lock.unlock()
            if finished { return }

            guard input.isReadyForMoreMediaData else { return }

            lock.lock()
            let frame: PendingFrame?
            if !pendingFrames.isEmpty {
                frame = pendingFrames.removeFirst()
            } else {
                frame = nil
            }
            let finishing = isFinishingEnqueue
            let empty = pendingFrames.isEmpty
            lock.unlock()

            if let frame = frame {
                let ok = adaptor.append(frame.pixelBuffer, withPresentationTime: frame.presentationTime)
                if !ok {
                    onError(VideoExportError.appendFailed(nil))
                    // Still call completion to unblock caller
                    frame.completion()
                    return
                }
                frame.completion()
            } else if finishing {
                // All frames drained and no more coming
                lock.lock()
                guard !isFinished else {
                    lock.unlock()
                    return
                }
                isFinished = true
                let cb = finishCallback
                finishCallback = nil
                lock.unlock()

                input.markAsFinished()
                cb?()
                return
            } else {
                // Queue empty, more frames may come — callback will be re-invoked by
                // requestMediaDataWhenReady or by kick in enqueue()
                return
            }
        }
    }
}
