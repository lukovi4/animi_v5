import TVECore

/// Shared helper for computing global timeline timeUs from a compressed frame.
/// Used by both preview (EditorRuntime) and export (TimelineExportRuntime) paths.
internal enum OverlayTimeMapping {
    /// Computes global timeUs for a compressed frame using transition math.
    /// Returns `nil` if the frame has no valid mapping.
    static func globalTimeUs(
        for compressedFrame: Int,
        math: TimelineTransitionMath,
        fps: Int
    ) -> TimeUs? {
        guard let mapping = math.frameMapping(for: compressedFrame) else { return nil }
        let sceneStartUs = math.sceneItems.prefix(mapping.sceneIndex).reduce(TimeUs(0)) { sum, item in
            sum + item.durationUs
        }
        let localTimeUs = frameToUs(mapping.localFrame, fps: fps)
        return sceneStartUs + localTimeUs
    }
}
