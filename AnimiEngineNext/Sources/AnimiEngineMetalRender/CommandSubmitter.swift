import Metal

/// Task-003 plan §8.6, §13.2 (correction #11) — the command-buffer commit/wait vs status-mapping seam.
///
/// This abstraction separates *committing and waiting once* from *mapping the completion result*, so a
/// test can inject a deterministic failed completion without claiming to hand-mark a real
/// `MTLCommandBuffer` as failed. Production `CommandSubmitter.swift` contains **only** the protocol,
/// `CommandCompletion`, and `RealCommandSubmitter`; the test-only `StubFailingSubmitter` lives in
/// `MetalResourceOwnershipTests.swift` (plan §10/§11.1, Rev-4 correction #3).
protocol CommandSubmitter {
    /// Make a fresh command buffer for one `execute()` (plan §8.6 step 6).
    func makeCommandBuffer() throws -> MTLCommandBuffer
    /// Commit the buffer and wait **exactly once** (plan §8.6 step 8), returning a mapped result.
    func commitAndWait(_ buffer: MTLCommandBuffer) -> CommandCompletion
}

/// The mapped outcome of committing+waiting on a command buffer (plan §8.6 step 9).
enum CommandCompletion: Equatable {
    case completed
    case failed(status: String, detail: String)
}

/// The production submitter: wraps the session-owned `MTLCommandQueue` (plan §8.6).
struct RealCommandSubmitter: CommandSubmitter {
    let queue: MTLCommandQueue

    func makeCommandBuffer() throws -> MTLCommandBuffer {
        guard let buffer = queue.makeCommandBuffer() else {
            throw MetalRenderError.commandBufferFailed(
                status: "noCommandBuffer", detail: "MTLCommandQueue.makeCommandBuffer() returned nil")
        }
        return buffer
    }

    func commitAndWait(_ buffer: MTLCommandBuffer) -> CommandCompletion {
        buffer.commit()
        buffer.waitUntilCompleted()
        if let error = buffer.error {
            return .failed(status: Self.describe(buffer.status), detail: String(describing: error))
        }
        guard buffer.status == .completed else {
            return .failed(status: Self.describe(buffer.status), detail: "command buffer did not complete")
        }
        return .completed
    }

    static func describe(_ status: MTLCommandBufferStatus) -> String {
        switch status {
        case .notEnqueued: return "notEnqueued"
        case .enqueued: return "enqueued"
        case .committed: return "committed"
        case .scheduled: return "scheduled"
        case .completed: return "completed"
        case .error: return "error"
        @unknown default: return "unknown"
        }
    }
}
