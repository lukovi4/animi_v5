import Foundation

/// Task-003 plan §8 — a complete, immutable rendered frame returned by the Metal executor.
///
/// A `RenderedFrame` is produced only after successful command completion (§8); there is no partial
/// representation. It owns a defensive copy of its readback bytes (canonical BGRA8 sRGB premultiplied)
/// and carries the colour contract plus a raw-output SHA-256 over dimensions, format/colour metadata
/// and pixel bytes (§8).
public struct RenderedFrame: Hashable, Sendable {
    public let dimensions: PixelDimensions
    public let colorContract: RenderColorContract
    /// The owned readback bytes — a defensive value copy of the caller's data (item 2).
    public let bytes: Data
    /// Lowercase hex SHA-256 over the domain-tagged dimensions/format/colour metadata and pixel bytes.
    public let rawOutputHash: String

    public init(dimensions: PixelDimensions, colorContract: RenderColorContract, bytes: Data) throws {
        // A complete frame's bytes must exactly match its dimensions — no partial readback (§8).
        guard bytes.count == dimensions.requiredByteCount else {
            throw RenderModelError.pixelByteCountMismatch(
                expected: dimensions.requiredByteCount, actual: bytes.count)
        }
        // Task-003 output is exactly BGRA8 (D3-08); a frame in any other format is unsupported.
        guard dimensions.format == .bgra8, colorContract.outputFormat == .bgra8 else {
            throw RenderModelError.unsupportedValue(
                field: "RenderedFrame.format", value: "\(dimensions.format)/\(colorContract.outputFormat)")
        }
        let owned = Data(bytes)                          // defensive copy (item 2)
        self.dimensions = dimensions
        self.colorContract = colorContract
        self.bytes = owned
        self.rawOutputHash = try RenderCanonicalEncoding.rawOutputHash(
            dimensions: dimensions, colorContract: colorContract, bytes: owned)
    }
}
