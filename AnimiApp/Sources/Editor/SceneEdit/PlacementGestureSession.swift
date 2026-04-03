import Foundation

/// Pure value struct for tracking placement gesture state across simultaneous gestures.
///
/// Created when the first gesture begins, destroyed when the last gesture ends.
/// All deltas are cumulative from gesture start; `currentPlacement()` applies them to baseline.
struct PlacementGestureSession {

    /// Block being transformed.
    let blockId: String

    /// Placement snapshot at gesture start (read from store).
    let baseline: MediaPlacementState

    /// Cumulative binding-local translation from gesture start.
    /// Converted from canvas-space via inverse edit binding world matrix.
    var translationDelta: (x: Double, y: Double) = (0, 0)

    /// Scale multiplier from UIPinchGestureRecognizer (1.0 = no change).
    var scaleDelta: Double = 1.0

    /// Rotation delta in radians from UIRotationGestureRecognizer.
    var rotationDelta: Double = 0

    /// Returns baseline + deltas, with clamping/normalization via `MediaPlacementState.init`.
    func currentPlacement() -> MediaPlacementState {
        let rotationDeltaDegrees = rotationDelta * 180.0 / .pi
        return MediaPlacementState(
            fitMode: baseline.fitMode,
            offsetX: baseline.offsetX + translationDelta.x,
            offsetY: baseline.offsetY + translationDelta.y,
            userScale: baseline.userScale * scaleDelta,
            rotationDegrees: baseline.rotationDegrees + rotationDeltaDegrees
        )
    }
}
