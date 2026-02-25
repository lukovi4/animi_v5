import Foundation

// MARK: - Timeline Performance Counters (PR4 DEBUG)

#if DEBUG

/// Track kind for performance instrumentation (PR4)
/// Named differently from CanonicalTimeline.TrackKind to avoid ambiguity
enum PerfTrackKind: String {
    case scene
    case audio
    case text
    case sticker
}

/// Global counters for timeline performance monitoring.
/// Used to verify that data updates don't happen during scroll/zoom.
///
/// Usage:
/// - Call `incrementApplySnapshot` when data path is executed
/// - Call `incrementLayout` when layout path is executed
/// - During scroll/zoom, `applySnapshot` count should NOT increase
enum TimelinePerfCounters {

    // MARK: - Counters

    private static var applySnapshotCounts: [PerfTrackKind: Int] = [:]
    private static var layoutCounts: [PerfTrackKind: Int] = [:]

    // MARK: - Increment

    /// Increments applySnapshot counter for given track kind.
    static func incrementApplySnapshot(_ kind: PerfTrackKind) {
        applySnapshotCounts[kind, default: 0] += 1
        print("[PerfCounter] applySnapshot(\(kind.rawValue)): \(applySnapshotCounts[kind]!)")
    }

    /// Increments layout counter for given track kind.
    static func incrementLayout(_ kind: PerfTrackKind) {
        layoutCounts[kind, default: 0] += 1
        // Layout is frequent, only log every 10th call to reduce noise
        if layoutCounts[kind]! % 10 == 0 {
            print("[PerfCounter] layout(\(kind.rawValue)): \(layoutCounts[kind]!)")
        }
    }

    // MARK: - Query

    /// Returns current applySnapshot count for given track kind.
    static func getApplySnapshotCount(_ kind: PerfTrackKind) -> Int {
        applySnapshotCounts[kind] ?? 0
    }

    /// Returns current layout count for given track kind.
    static func getLayoutCount(_ kind: PerfTrackKind) -> Int {
        layoutCounts[kind] ?? 0
    }

    // MARK: - Reset

    /// Resets all counters. Call before QA tests or unit tests.
    static func reset() {
        applySnapshotCounts.removeAll()
        layoutCounts.removeAll()
        print("[PerfCounter] reset")
    }

    // MARK: - Summary

    /// Prints summary of all counters.
    static func printSummary() {
        print("[PerfCounter] === Summary ===")
        for kind in [PerfTrackKind.scene, .audio, .text, .sticker] {
            let snapshot = applySnapshotCounts[kind] ?? 0
            let layout = layoutCounts[kind] ?? 0
            if snapshot > 0 || layout > 0 {
                print("[PerfCounter] \(kind.rawValue): applySnapshot=\(snapshot), layout=\(layout)")
            }
        }
        print("[PerfCounter] ===============")
    }
}

#endif
