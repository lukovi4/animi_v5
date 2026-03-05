import Foundation
import os.signpost

// MARK: - Scrub Diagnostics (DEBUG only)
// ТЗ: 100% диагностика дёргания скролла таймлайна при ручном scrub
// Инструментация через os_signpost для Instruments (Points of Interest)

#if DEBUG

// MARK: - Debug Toggles (UserDefaults)

/// Debug toggles for A/B testing scrub performance.
/// Use launch arguments or UserDefaults to toggle without rebuild.
///
/// Launch arguments:
/// - `-DebugSkipScrubVideoUpdates YES` - skip updateVideoFramesForScrub
/// - `-DebugSkipEditorControllerTimeUpdate YES` - skip editorController.setCurrentTimeUs
/// - `-DebugSkipMetalRender YES` - skip metalView.setNeedsDisplay during scrub
/// - `-DebugThrottleRender30Hz YES` - throttle render to 30Hz during scrub
enum ScrubDebugToggles {

    /// H1: Skip `updateVideoFramesForScrub` during timeline drag.
    /// If enabling this makes scroll smooth → root cause confirmed.
    static var skipScrubVideoUpdates: Bool {
        UserDefaults.standard.bool(forKey: "DebugSkipScrubVideoUpdates")
    }

    /// H2: Skip `editorController.setCurrentTimeUs` during drag.
    /// Test only if H1 is not confirmed.
    static var skipEditorControllerTimeUpdate: Bool {
        UserDefaults.standard.bool(forKey: "DebugSkipEditorControllerTimeUpdate")
    }

    /// H3: Skip `metalView.setNeedsDisplay()` during scrub drag.
    /// If enabling this makes scroll smooth → render pipeline is the bottleneck.
    /// Final render is forced on .ended to ensure preview matches final position.
    static var skipMetalRender: Bool {
        UserDefaults.standard.bool(forKey: "DebugSkipMetalRender")
    }

    /// H3-throttle: Throttle `metalView.setNeedsDisplay()` to 30Hz during scrub drag.
    /// If this makes scroll smooth while keeping preview alive → candidate for release fix.
    static var throttleRender30Hz: Bool {
        UserDefaults.standard.bool(forKey: "DebugThrottleRender30Hz")
    }
}

// MARK: - os_signpost Logger

/// Signpost logger for scrub diagnostics.
/// View in Instruments → Points of Interest.
enum ScrubSignpost {

    /// Subsystem for Instruments filtering
    static let subsystem = "com.animi.scrub-diagnostics"

    /// Log handle for signposts
    static let log = OSLog(subsystem: subsystem, category: .pointsOfInterest)

    // MARK: - Signpost IDs (for begin/end pairing)

    /// Signpost names as StaticString (required by os_signpost)
    private static let scrollViewDidScrollName: StaticString = "scrollViewDidScroll"
    private static let handlePlayheadChangedName: StaticString = "handlePlayheadChanged"
    private static let updateVideoFramesForScrubName: StaticString = "updateVideoFramesForScrub"
    private static let setCurrentTimeUsName: StaticString = "setCurrentTimeUs"
    private static let timeRulerDrawName: StaticString = "TimeRulerView.draw"

    // MARK: - TimelineView.scrollViewDidScroll

    /// Begin interval for scrollViewDidScroll
    static func beginScrollViewDidScroll() -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: scrollViewDidScrollName, signpostID: id)
        return id
    }

    /// End interval for scrollViewDidScroll
    static func endScrollViewDidScroll(_ id: OSSignpostID) {
        os_signpost(.end, log: log, name: scrollViewDidScrollName, signpostID: id)
    }

    /// Event: scrub .changed emitted
    static func emitScrubChanged(timeUs: Int64) {
        os_signpost(.event, log: log, name: "scrubChanged", "timeUs: %lld", timeUs)
    }

    /// Event: clamp hit (rawX != clampedX)
    static func emitClampHit() {
        os_signpost(.event, log: log, name: "clampHit")
    }

    // MARK: - PlayerViewController.handlePlayheadChanged

    /// Begin interval for handlePlayheadChanged (total)
    static func beginHandlePlayheadChanged() -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: handlePlayheadChangedName, signpostID: id)
        return id
    }

    /// End interval for handlePlayheadChanged
    static func endHandlePlayheadChanged(_ id: OSSignpostID, syncPath: Bool) {
        os_signpost(.end, log: log, name: handlePlayheadChangedName, signpostID: id, "syncPath: %d", syncPath ? 1 : 0)
    }

    // MARK: - UserMediaService.updateVideoFramesForScrub

    /// Begin interval for updateVideoFramesForScrub
    static func beginUpdateVideoFramesForScrub() -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: updateVideoFramesForScrubName, signpostID: id)
        return id
    }

    /// End interval for updateVideoFramesForScrub
    static func endUpdateVideoFramesForScrub(_ id: OSSignpostID, blockCount: Int) {
        os_signpost(.end, log: log, name: updateVideoFramesForScrubName, signpostID: id, "blocks: %d", blockCount)
    }

    // MARK: - TemplateEditorController.setCurrentTimeUs

    /// Begin interval for setCurrentTimeUs
    static func beginSetCurrentTimeUs() -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: setCurrentTimeUsName, signpostID: id)
        return id
    }

    /// End interval for setCurrentTimeUs
    static func endSetCurrentTimeUs(_ id: OSSignpostID) {
        os_signpost(.end, log: log, name: setCurrentTimeUsName, signpostID: id)
    }

    // MARK: - TimeRulerView.draw (optional, if H3 needs testing)

    /// Begin interval for TimeRulerView.draw
    static func beginTimeRulerDraw() -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: timeRulerDrawName, signpostID: id)
        return id
    }

    /// End interval for TimeRulerView.draw
    static func endTimeRulerDraw(_ id: OSSignpostID) {
        os_signpost(.end, log: log, name: timeRulerDrawName, signpostID: id)
    }
}

// MARK: - Calls/sec Counter (optional, for print diagnostics)

/// Simple calls-per-second counter for console output.
/// Complements signposts with quick numeric feedback.
final class ScrubCallCounter {

    static let shared = ScrubCallCounter()

    private var scrollViewDidScrollCount = 0
    private var scrubChangedCount = 0
    private var handlePlayheadChangedCount = 0
    private var clampHitCount = 0

    private var lastReportTime: CFAbsoluteTime = 0
    private let reportInterval: CFAbsoluteTime = 1.0 // 1 second

    private init() {
        lastReportTime = CFAbsoluteTimeGetCurrent()
    }

    func recordScrollViewDidScroll() {
        scrollViewDidScrollCount += 1
        checkAndReport()
    }

    func recordScrubChanged() {
        scrubChangedCount += 1
    }

    func recordHandlePlayheadChanged() {
        handlePlayheadChangedCount += 1
    }

    func recordClampHit() {
        clampHitCount += 1
    }

    private func checkAndReport() {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastReportTime

        if elapsed >= reportInterval {
            let scrollPerSec = Double(scrollViewDidScrollCount) / elapsed
            let scrubPerSec = Double(scrubChangedCount) / elapsed
            let playheadPerSec = Double(handlePlayheadChangedCount) / elapsed
            let clampPerSec = Double(clampHitCount) / elapsed

            print(String(format: "[SCRUB-DIAG] scroll: %.1f/s | scrubChanged: %.1f/s | playhead: %.1f/s | clamp: %.1f/s",
                         scrollPerSec, scrubPerSec, playheadPerSec, clampPerSec))

            // Reset
            scrollViewDidScrollCount = 0
            scrubChangedCount = 0
            handlePlayheadChangedCount = 0
            clampHitCount = 0
            lastReportTime = now
        }
    }

    /// Force report current stats (call on drag end)
    func forceReport() {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastReportTime
        guard elapsed > 0.1 else { return } // Minimum interval

        let scrollPerSec = Double(scrollViewDidScrollCount) / elapsed
        let scrubPerSec = Double(scrubChangedCount) / elapsed
        let playheadPerSec = Double(handlePlayheadChangedCount) / elapsed

        print(String(format: "[SCRUB-DIAG] FINAL - scroll: %.1f/s | scrubChanged: %.1f/s | playhead: %.1f/s (elapsed: %.2fs)",
                     scrollPerSec, scrubPerSec, playheadPerSec, elapsed))

        // Reset
        scrollViewDidScrollCount = 0
        scrubChangedCount = 0
        handlePlayheadChangedCount = 0
        clampHitCount = 0
        lastReportTime = now
    }
}

#endif
