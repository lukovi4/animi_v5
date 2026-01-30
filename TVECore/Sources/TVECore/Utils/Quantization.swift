import Foundation

/// Quantization and comparison utilities for deterministic hashing and caching.
/// These functions ensure consistent behavior across different runs and devices
/// by eliminating floating-point noise in comparisons and hash keys.
public enum Quantization {
    // MARK: - Quantization

    /// Quantizes a value to the nearest multiple of step.
    /// - Parameters:
    ///   - value: The value to quantize
    ///   - step: The quantization step (e.g., 1/1024 for sub-pixel precision)
    /// - Returns: The quantized value
    /// - Note: Used for visual output where quantized values are rendered.
    ///         For hash keys, prefer `quantizedInt` to avoid float representation issues.
    @inlinable
    public static func quantize(_ value: Double, step: Double) -> Double {
        (value / step).rounded() * step
    }

    /// Converts a value to a quantized integer for deterministic hashing.
    /// - Parameters:
    ///   - value: The value to quantize
    ///   - step: The quantization step (e.g., 1/1024)
    /// - Returns: Integer representation suitable for hashing
    /// - Note: This is the preferred method for building hash keys.
    ///         Using Int avoids any float representation issues in hash computation.
    @inlinable
    public static func quantizedInt(_ value: Double, step: Double) -> Int {
        Int((value / step).rounded())
    }

    // MARK: - Comparisons

    /// Checks if two values are nearly equal within epsilon.
    /// - Parameters:
    ///   - a: First value
    ///   - b: Second value
    ///   - epsilon: Maximum allowed difference (default: AnimConstants.nearlyEqualEpsilon)
    /// - Returns: true if |a - b| < epsilon
    @inlinable
    public static func isNearlyEqual(
        _ a: Double,
        _ b: Double,
        epsilon: Double = AnimConstants.nearlyEqualEpsilon
    ) -> Bool {
        abs(a - b) < epsilon
    }

    /// Checks if a value is nearly zero within epsilon.
    /// - Parameters:
    ///   - value: The value to check
    ///   - epsilon: Maximum allowed absolute value (default: AnimConstants.nearlyEqualEpsilon)
    /// - Returns: true if |value| < epsilon
    @inlinable
    public static func isNearlyZero(
        _ value: Double,
        epsilon: Double = AnimConstants.nearlyEqualEpsilon
    ) -> Bool {
        abs(value) < epsilon
    }

    /// Checks if two keyframe times are considered equal.
    /// - Parameters:
    ///   - t1: First keyframe time
    ///   - t2: Second keyframe time
    /// - Returns: true if |t1 - t2| < keyframeTimeEpsilon
    @inlinable
    public static func keyframeTimesEqual(_ t1: Double, _ t2: Double) -> Bool {
        abs(t1 - t2) < AnimConstants.keyframeTimeEpsilon
    }
}
