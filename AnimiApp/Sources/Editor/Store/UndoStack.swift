import Foundation

// MARK: - Undo Stack (PR2: Snapshot-based Undo/Redo)

/// Manages undo/redo stack using snapshots.
/// Limit is defined by EditorConfig.undoStackLimit.
public struct UndoStack: Sendable {

    // MARK: - Stacks

    /// Stack of snapshots for undo (most recent at end).
    private var undoStack: [EditorSnapshot] = []

    /// Stack of snapshots for redo (most recent at end).
    private var redoStack: [EditorSnapshot] = []

    /// Maximum number of snapshots in undo stack.
    private let limit: Int

    // MARK: - Initialization

    public init(limit: Int = EditorConfig.undoStackLimit) {
        self.limit = limit
    }

    // MARK: - State

    /// Returns true if undo is available.
    public var canUndo: Bool {
        !undoStack.isEmpty
    }

    /// Returns true if redo is available.
    public var canRedo: Bool {
        !redoStack.isEmpty
    }

    /// Number of undo steps available.
    public var undoCount: Int {
        undoStack.count
    }

    /// Number of redo steps available.
    public var redoCount: Int {
        redoStack.count
    }

    // MARK: - Operations

    /// Pushes a snapshot onto the undo stack.
    /// Clears redo stack (new action invalidates redo history).
    /// Enforces limit by removing oldest snapshots.
    /// - Parameter snapshot: The snapshot to push
    public mutating func push(_ snapshot: EditorSnapshot) {
        undoStack.append(snapshot)

        // Enforce limit
        if undoStack.count > limit {
            undoStack.removeFirst(undoStack.count - limit)
        }

        // Clear redo stack (new action invalidates redo)
        redoStack.removeAll()
    }

    /// Pops a snapshot from undo stack and pushes current state to redo.
    /// - Parameter currentSnapshot: Current state to push to redo stack
    /// - Returns: The snapshot to restore, or nil if undo stack is empty
    public mutating func undo(currentSnapshot: EditorSnapshot) -> EditorSnapshot? {
        guard let snapshot = undoStack.popLast() else {
            return nil
        }

        // Push current state to redo
        redoStack.append(currentSnapshot)

        return snapshot
    }

    /// Pops a snapshot from redo stack and pushes current state to undo.
    /// - Parameter currentSnapshot: Current state to push to undo stack
    /// - Returns: The snapshot to restore, or nil if redo stack is empty
    public mutating func redo(currentSnapshot: EditorSnapshot) -> EditorSnapshot? {
        guard let snapshot = redoStack.popLast() else {
            return nil
        }

        // Push current state to undo (PR2.1 fix: was incorrectly pushing snapshot)
        undoStack.append(currentSnapshot)

        return snapshot
    }

    /// Clears both stacks.
    public mutating func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}

// MARK: - Debug

#if DEBUG
public extension UndoStack {
    /// Debug description of stack state.
    var debugDescription: String {
        "UndoStack(undo: \(undoCount), redo: \(redoCount), limit: \(limit))"
    }
}
#endif
