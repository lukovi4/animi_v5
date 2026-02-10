import Foundation

// MARK: - Mask Operation

/// Single mask operation for GPU accumulation.
/// Extracted from RenderCommand.beginMask during scope extraction.
struct MaskOp: Sendable, Equatable {
    /// Boolean operation mode (add/subtract/intersect)
    let mode: MaskMode

    /// Whether mask coverage is inverted before application
    let inverted: Bool

    /// Path ID for triangulated mask geometry
    let pathId: PathID

    /// Mask opacity [0.0...1.0]
    let opacity: Double

    /// Animation frame for animated paths
    let frame: Double
}

// MARK: - Mask Group Scope

/// Extracted mask group scope containing all mask operations
/// and range of inner commands to be rendered with mask applied.
///
/// Structure corresponds to LIFO-nested mask commands in AE order:
/// ```
/// beginMask(M2) → beginMask(M1) → beginMask(M0) → [inner] → endMask → endMask → endMask
/// ```
/// After extraction: `opsInAeOrder = [M0, M1, M2]` (reversed for correct application order)
///
/// Inner commands may themselves contain nested mask scopes (e.g. inputClip inside
/// a container mask). These are passed verbatim and handled recursively by `drawInternal`.
///
/// **PR Hot Path:** Uses `Range<Int>` instead of `[RenderCommand]` to avoid allocations.
struct MaskGroupScope: Sendable {
    /// Mask operations in AE application order.
    /// First mask in array is applied first (was innermost in LIFO nesting).
    let opsInAeOrder: [MaskOp]

    /// Range of inner commands within the parent command array.
    /// Commands in this range are rendered to bbox-sized content texture.
    let innerRange: Range<Int>

    /// Index of the next command after the scope (after last endMask).
    /// Used for index jumping in execute loop.
    let endIndex: Int
}

// MARK: - Initial Accumulator Value

/// Returns initial accumulator value based on first mask operation mode.
///
/// - `add` first: acc = 0.0 (start empty, add coverage)
/// - `subtract` first: acc = 1.0 (start full, subtract coverage)
/// - `intersect` first: acc = 1.0 (start full, intersect with coverage)
///
/// - Parameter opsInAeOrder: Mask operations in AE application order
/// - Returns: Initial accumulator value (0.0 or 1.0)
func initialAccumulatorValue(for opsInAeOrder: [MaskOp]) -> Float {
    guard let first = opsInAeOrder.first else { return 0 }
    switch first.mode {
    case .add:
        return 0
    case .subtract, .intersect:
        return 1
    }
}
