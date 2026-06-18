import Foundation
import AnimiEngineCore
import AnimiEngineRenderModel

/// Task-003 plan §5.4, §17 step 7 — the adapter-boundary numeric conversion and the canonical,
/// domain-separated template/material hashing.
///
/// Two concerns live here, both pure and deterministic with no IO:
///
///   1. **`FixedPointConversion`** — the *only* place a `Double` becomes a fixed-point `Int64`. It
///      uses round-to-nearest, ties-away-from-zero, and rejects NaN, infinity and any value whose
///      rounded magnitude overflows `Int64`. No `Float`/`Double` survives past this boundary into
///      canonical or render-material state (§5.4, item 4).
///   2. **`TemplateContentHash`** — canonical, insertion-order-independent, domain-separated SHA-256
///      hashes for the converted template and its material table (item 6), built on the render model's
///      `RenderCanonicalEncoding` so the bytes are identical to the rest of the render model.

// MARK: - Numeric conversion errors

/// Typed numeric-conversion failures at the `Double` → fixed-point adapter boundary (§5.4, item 4).
/// Every failure is reported, never absorbed into a default or a trap.
public enum TemplateNumericConversionError: Error, Equatable, Sendable {
    /// The authored value was NaN.
    case notANumber(field: String)
    /// The authored value was +∞ or −∞.
    case notFinite(field: String)
    /// The rounded fixed-point magnitude does not fit `Int64`.
    case fixedPointOverflow(field: String, value: Double)
    /// An exact integer narrowing (e.g. a composition size) was non-finite, fractional, or out of
    /// `Int64` range.
    case integerOutOfRange(field: String, value: Double)
    /// An exact `Double` → rational conversion produced a numerator or denominator that does not fit
    /// `Int64` (item 5).
    case rationalOverflow(field: String, value: Double)
}

/// The single `Double` → fixed-point conversion boundary (§5.4, item 4).
///
/// All conversions round half **away from zero** (so `+0.5 → +1`, `−0.5 → −1`), matching the §17
/// step-7 rounding contract, and fail closed on NaN / infinity / overflow.
public enum FixedPointConversion {

    /// Rounds an authored `Double` to the nearest integer, ties away from zero, rejecting NaN and
    /// infinity. The result is the raw rounded value as a `Double` still (callers narrow it).
    private static func roundedHalfAwayFromZero(_ value: Double, field: String) throws -> Double {
        if value.isNaN { throw TemplateNumericConversionError.notANumber(field: field) }
        if value.isInfinite { throw TemplateNumericConversionError.notFinite(field: field) }
        // Swift's `.rounded(.toNearestOrAwayFromZero)` is exactly the documented rule.
        return value.rounded(.toNearestOrAwayFromZero)
    }

    /// Converts an authored `Double` measured in *fixed-point units of `value`* (already scaled) into a
    /// checked `Int64` raw value. Rejects NaN/inf/overflow.
    private static func narrowToInt64(_ rounded: Double, field: String, original: Double) throws -> Int64 {
        // After rounding, `rounded` is integral. It fits Int64 iff it is within [Int64.min, Int64.max].
        // Use the exact Double bounds: Int64.max is 9.223372036854776e18 which rounds up past the
        // representable max, so compare against 2^63 directly.
        let lowerBound = -9_223_372_036_854_775_808.0   // Int64.min exactly (a power of two, exact in Double)
        let upperBoundExclusive = 9_223_372_036_854_775_808.0  // 2^63, first value that does NOT fit Int64
        guard rounded >= lowerBound, rounded < upperBoundExclusive else {
            throw TemplateNumericConversionError.fixedPointOverflow(field: field, value: original)
        }
        return Int64(rounded)
    }

    /// Converts an authored canvas-point `Double` into a `CanvasScalar` raw `Int64`
    /// (65,536 units per point), round half away from zero, fail-closed.
    public static func canvasScalar(points value: Double, field: String) throws -> CanvasScalar {
        let scaled = value * Double(CanvasScalar.unitsPerPoint)
        let rounded = try roundedHalfAwayFromZero(scaled, field: field)
        return CanvasScalar(rawValue: try narrowToInt64(rounded, field: field, original: value))
    }

    /// Converts an authored **percent** scale `Double` (AnimIR encodes 100 == 1.0) into a `ScaleScalar`
    /// (1,000,000 raw units per 1.0), round half away from zero, fail-closed. Authored `100` therefore
    /// becomes exactly `1_000_000`.
    public static func scaleScalar(percent value: Double, field: String) throws -> ScaleScalar {
        // 100 percent → 1.0 → 1_000_000 raw. Factor = unitsPerUnit / 100 = 10_000.
        let scaled = value * (Double(ScaleScalar.unitsPerUnit) / 100.0)
        let rounded = try roundedHalfAwayFromZero(scaled, field: field)
        return ScaleScalar(rawValue: try narrowToInt64(rounded, field: field, original: value))
    }

    /// Converts an authored **percent** opacity `Double` (`0...100`) into an `OpacityScalar`
    /// (`[0, 1]`, 1,000,000 units per 1.0) after dividing by 100, round half away, fail-closed.
    /// Authored `100` becomes exactly `1_000_000`.
    public static func opacity(percent value: Double, field: String) throws -> OpacityScalar {
        let scaled = value * (Double(OpacityScalar.unitsPerUnit) / 100.0)
        let rounded = try roundedHalfAwayFromZero(scaled, field: field)
        return try OpacityScalar(rawValue: try narrowToInt64(rounded, field: field, original: value))
    }

    /// Converts an authored **unit** opacity `Double` (`0...1`) into an `OpacityScalar` directly,
    /// round half away, fail-closed.
    public static func opacity(unit value: Double, field: String) throws -> OpacityScalar {
        let scaled = value * Double(OpacityScalar.unitsPerUnit)
        let rounded = try roundedHalfAwayFromZero(scaled, field: field)
        return try OpacityScalar(rawValue: try narrowToInt64(rounded, field: field, original: value))
    }

    /// Converts an authored dimensionless `Double` (easing tangents, miter limit) into a raw `Int64`
    /// at 1,000,000 units per unit, round half away, fail-closed.
    public static func dimensionlessRaw(_ value: Double, field: String) throws -> Int64 {
        let scaled = value * 1_000_000.0
        let rounded = try roundedHalfAwayFromZero(scaled, field: field)
        return try narrowToInt64(rounded, field: field, original: value)
    }

    /// Exact rational conversion of a **finite** authored `Double` into a `RationalSourceTime`, built
    /// directly from `Double.bitPattern` — **no** approximate floating reconstruction and **no**
    /// decimal quantization (item 5). A finite IEEE-754 double is exactly `sign · M · 2^e` for an
    /// integer mantissa `M`; this forms that exact numerator/denominator (a power-of-two denominator),
    /// cancels shared powers of two, and narrows to `Int64`, throwing a typed overflow when the exact
    /// numerator or denominator does not fit. `Int64.min` is representable; `±0` both map to zero.
    public static func exactRational(_ value: Double, field: String) throws -> RationalSourceTime {
        if value.isNaN { throw TemplateNumericConversionError.notANumber(field: field) }
        if value.isInfinite { throw TemplateNumericConversionError.notFinite(field: field) }

        let bits = value.bitPattern
        let negative = (bits >> 63) == 1
        let rawExponent = Int((bits >> 52) & 0x7FF)            // 11-bit biased exponent
        let rawFraction = bits & 0x000F_FFFF_FFFF_FFFF          // 52-bit fraction

        // Both +0 and -0 map to zero.
        if rawExponent == 0 && rawFraction == 0 { return .zero }

        // Integer mantissa M and unbiased base-2 exponent E such that |value| = M · 2^E.
        //   normal   : M = (1<<52) | fraction, E = rawExponent - 1075   (1075 = bias 1023 + 52)
        //   subnormal: M = fraction,           E = -1074
        let mantissaU: UInt64
        var exponent: Int
        if rawExponent == 0 {
            mantissaU = rawFraction
            exponent = -1074
        } else {
            mantissaU = (UInt64(1) << 52) | rawFraction
            exponent = rawExponent - 1075
        }

        // Strip trailing zero bits of the mantissa into the exponent (exact reduction).
        var m = mantissaU
        while (m & 1) == 0 { m >>= 1; exponent += 1 }

        // |value| = m · 2^exponent, with m odd. Build numerator / denominator (each a fit-checked Int64).
        var numeratorMagnitude = m                 // odd, < 2^53 — always fits UInt64/Int64 magnitude
        var denominator: UInt64 = 1
        if exponent >= 0 {
            // numerator = m · 2^exponent.
            var s = exponent
            while s > 0 {
                let (v, ov) = numeratorMagnitude.multipliedReportingOverflow(by: 2)
                if ov { throw TemplateNumericConversionError.rationalOverflow(field: field, value: value) }
                numeratorMagnitude = v; s -= 1
            }
        } else {
            // denominator = 2^(-exponent); m is odd so no further cancellation is possible.
            var s = -exponent
            while s > 0 {
                let (v, ov) = denominator.multipliedReportingOverflow(by: 2)
                if ov { throw TemplateNumericConversionError.rationalOverflow(field: field, value: value) }
                denominator = v; s -= 1
            }
        }

        // Narrow the signed numerator, allowing the exact Int64.min boundary when negative.
        let numerator: Int64
        if negative {
            if numeratorMagnitude == UInt64(Int64.max) + 1 {
                numerator = Int64.min
            } else if numeratorMagnitude <= UInt64(Int64.max) {
                numerator = -Int64(numeratorMagnitude)
            } else {
                throw TemplateNumericConversionError.rationalOverflow(field: field, value: value)
            }
        } else {
            guard numeratorMagnitude <= UInt64(Int64.max) else {
                throw TemplateNumericConversionError.rationalOverflow(field: field, value: value)
            }
            numerator = Int64(numeratorMagnitude)
        }
        guard denominator <= UInt64(Int64.max) else {
            throw TemplateNumericConversionError.rationalOverflow(field: field, value: value)
        }
        return try RationalSourceTime(numerator: numerator, denominator: Int64(denominator))
    }

    /// Converts an authored degree `Double` into a `RotationScalar` raw `Int64`
    /// (1,000 units per degree), round half away from zero, fail-closed.
    public static func rotationScalar(degrees value: Double, field: String) throws -> RotationScalar {
        let scaled = value * Double(RotationScalar.unitsPerDegree)
        let rounded = try roundedHalfAwayFromZero(scaled, field: field)
        return RotationScalar(rawValue: try narrowToInt64(rounded, field: field, original: value))
    }

    /// Converts an authored colour component `Double` (expected in `[0, 1]`) into a
    /// `NormalizedColorComponent` (1,000,000 units per 1.0), round half away, fail-closed. A value
    /// outside `[0, 1]` is rejected by the component's own range check.
    public static func normalizedColorComponent(_ value: Double, field: String) throws -> NormalizedColorComponent {
        let scaled = value * Double(NormalizedColorComponent.unitsPerUnit)
        let rounded = try roundedHalfAwayFromZero(scaled, field: field)
        let raw = try narrowToInt64(rounded, field: field, original: value)
        return try NormalizedColorComponent(rawValue: raw)
    }

    /// Converts an authored `Double` into a raw `Int64` scaled by `scale`, round half away from zero,
    /// rejecting NaN/inf/overflow. Used for exact-rational time numerators.
    public static func scaledInteger(_ value: Double, scale: Int64, field: String) throws -> Int64 {
        let scaled = value * Double(scale)
        let rounded = try roundedHalfAwayFromZero(scaled, field: field)
        return try narrowToInt64(rounded, field: field, original: value)
    }

    /// Narrows an authored `Double` that must be an exact whole number (e.g. a composition pixel size)
    /// into an `Int64`, rejecting NaN/inf/fractional/out-of-range. Unlike the scalar conversions this
    /// does **not** round — a non-integral authored size is an error, not a value to round.
    public static func exactInteger(_ value: Double, field: String) throws -> Int64 {
        if value.isNaN { throw TemplateNumericConversionError.notANumber(field: field) }
        if value.isInfinite { throw TemplateNumericConversionError.notFinite(field: field) }
        guard value.rounded(.towardZero) == value else {
            throw TemplateNumericConversionError.integerOutOfRange(field: field, value: value)
        }
        let lowerBound = -9_223_372_036_854_775_808.0
        let upperBoundExclusive = 9_223_372_036_854_775_808.0
        guard value >= lowerBound, value < upperBoundExclusive else {
            throw TemplateNumericConversionError.integerOutOfRange(field: field, value: value)
        }
        return Int64(value)
    }
}

// MARK: - Separate, domain-separated hashes (item 4, item 6)

/// Three distinct, deterministic, domain-separated hashes (Stage-6 correction item 4):
///
///   * `compiledTemplateHash` — SHA-256 over the **raw `.tve` input bytes**, behind a domain tag.
///     It depends only on the compiled bytes — never on selection, media bindings, or scene instance
///     ids (those are not inputs to it).
///   * `projectHash` — SHA-256 over the **canonical project bytes** (the converter encodes the
///     document once and hashes those exact bytes), behind a distinct domain tag.
///   * `materialHash` — the complete selected material program table hash (`RenderMaterialTable`).
///
/// The two byte-hashes prepend a domain tag so a compiled-input hash can never collide with a project
/// hash even on coincident bytes.
public enum TemplateContentHash {

    private static let compiledDomainTag = "aen.compiledTemplateInput.v1"
    private static let projectDomainTag = "aen.canonicalProject.v1"

    /// SHA-256 over the raw compiled `.tve` bytes, domain-tagged. Independent of selection/media/ids.
    public static func compiledTemplateHash(_ data: Data) -> String {
        var combined = Data(compiledDomainTag.utf8)
        combined.append(0x00)
        combined.append(data)
        return RenderCanonicalEncoding.sha256Hex(combined)
    }

    /// SHA-256 over the canonical project bytes, domain-tagged.
    public static func projectHash(_ canonicalProjectBytes: Data) -> String {
        var combined = Data(projectDomainTag.utf8)
        combined.append(0x00)
        combined.append(canonicalProjectBytes)
        return RenderCanonicalEncoding.sha256Hex(combined)
    }

    /// Domain-scoped SHA-256 over the material table (delegates to the render-model material domain).
    public static func materialHash(_ table: RenderMaterialTable) throws -> String {
        try table.contentHash()
    }
}
