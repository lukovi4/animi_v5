import Foundation

/// Shared constants for animation processing (PR-14A: Determinism & Hashing).
///
/// Centralizes epsilon values and quantization steps to ensure **numeric determinism**
/// and **cache hit stability within a single process run**.
///
/// - Note: "Determinism" here refers to:
///   - Eliminating floating-point noise (1e-12 differences) from cache key computation
///   - Consistent epsilon usage for comparisons (keyframe times, tangent zero-checks, etc.)
///   - Stable cache behavior within a single app session
///
/// - Important: Quantized hashes use Swift's `Hasher`, which is **NOT stable across app launches**.
///   This is acceptable for in-memory caches (ShapeCache, StrokeCache).
///   For cross-run determinism (disk cache, snapshot tests), a `StableHasher` would be needed.
public enum AnimConstants {
    // MARK: - Epsilon Values

    /// Epsilon for comparing keyframe times (in frames).
    /// Two keyframe times are considered equal if |t1 - t2| < keyframeTimeEpsilon.
    /// Used in validator and extractor for keyframe matching.
    public static let keyframeTimeEpsilon: Double = 0.001

    /// Epsilon for general "nearly equal" floating-point comparisons.
    /// Used for skew checks, scale uniformity, tangent zero-checks, etc.
    public static let nearlyEqualEpsilon: Double = 0.001

    // MARK: - Quantization Steps

    /// Quantization step for matrix components (a, b, c, d, tx, ty).
    /// Used to compute deterministic hash keys for cache lookups.
    /// Step = 1/1024 ≈ 0.0009765625 provides sub-pixel precision without visual artifacts.
    public static let matrixQuantStep: Double = 1.0 / 1024.0

    /// Quantization step for path coordinates (vertices, tangents).
    /// Same as matrixQuantStep for consistency.
    /// Coordinates are quantized only for hash computation, not for actual geometry.
    public static let pathCoordQuantStep: Double = 1.0 / 1024.0

    /// Quantization step for stroke width in cache keys.
    /// Step = 1/8 provides 0.125px precision, balancing cache hit rate and visual quality.
    public static let strokeWidthQuantStep: Double = 1.0 / 8.0

    /// Quantization step for animation frames in path sampling cache keys (PR-14B).
    /// Scrub/preview may produce fractional frames; 1/1000 provides adequate precision
    /// without degrading cache hit rate during smooth playback.
    public static let frameQuantStep: Double = 1.0 / 1000.0
}
