import Foundation

/// Dual-baseline dirty model for editor session.
///
/// Tracks two baselines:
/// - `materializedBaseline`: last state the user explicitly saved or exported (durable).
/// - `recoveryBaseline`: last state written to the recovery slot (autosave).
///
/// This separation means autosave doesn't suppress the close prompt — the user
/// is only considered "clean" when current state matches the materialized baseline.
struct EditorSessionDirtyState {
    /// Last user-visible durable state (after save/export).
    private(set) var materializedBaseline: EditorSessionSnapshot
    /// Last state written to recovery slot.
    private(set) var recoveryBaseline: EditorSessionSnapshot

    init(baseline: EditorSessionSnapshot) {
        self.materializedBaseline = baseline
        self.recoveryBaseline = baseline
    }

    func isDirtyForUser(current: EditorSessionSnapshot) -> Bool {
        current != materializedBaseline
    }

    func needsRecoveryWrite(current: EditorSessionSnapshot) -> Bool {
        current != recoveryBaseline
    }

    mutating func didMaterialize(current: EditorSessionSnapshot) {
        materializedBaseline = current
        recoveryBaseline = current
    }

    mutating func didWriteRecovery(current: EditorSessionSnapshot) {
        recoveryBaseline = current
    }
}
