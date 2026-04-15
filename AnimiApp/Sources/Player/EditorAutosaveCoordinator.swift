import Foundation

/// Owns the periodic autosave timer and background/disappear save triggers.
/// Delegates actual persistence to `EditorSession.persistCheckpointIfNeeded()`.
@MainActor
final class EditorAutosaveCoordinator {

    private let session: EditorSession
    private var timer: Timer?

    init(session: EditorSession) {
        self.session = session
    }

    /// Starts the periodic autosave timer.
    func start(interval: TimeInterval = 30) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { [weak self] in await self?.session.persistCheckpointIfNeeded() }
        }
    }

    /// Stops the autosave timer.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Nonisolated stop for use from deinit. Timer invalidation is thread-safe.
    nonisolated func stopFromDeinit() {
        MainActor.assumeIsolated {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Handles app entering background — checkpoint immediately.
    func handleBackgrounding() {
        Task { await session.persistCheckpointIfNeeded() }
    }

    /// Handles view disappearing (permanent leave) — checkpoint immediately.
    func handleDisappear() {
        Task { await session.persistCheckpointIfNeeded() }
    }
}
