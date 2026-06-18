import Foundation
import AnimiEngineCore

/// Task-003 plan §6, §8 — owned, immutable pixel data plus its validated descriptor.
///
/// A `ResolvedPixelInput` carries the actual bytes of a resolved image / still-frame fixture / overlay
/// (§6 `ResolvedFrameInput` "owned pixel buffers"). It holds **no** URL, path, closure, provider, lazy
/// load or cache — only validated bytes and metadata. Construction is strict: malformed dimensions,
/// an under-sized stride, integer overflow in the size arithmetic, or a byte count that disagrees with
/// `height * bytesPerRow` is a typed failure (§9), never silently padded, truncated, or trapped.

/// The presentation orientation of a pixel buffer (step-8 corrective, issue #5). The 8 cases mirror the
/// EXIF orientation model. Fixture pixels are required to be in the canonical presentation orientation
/// ``up`` — i.e. already rotated/flipped so that `width`/`height` are the displayed dimensions and no
/// downstream re-orientation is needed. The orientation is an explicit part of the descriptor and the
/// content hash, so two otherwise-identical buffers with different orientations never collide.
public enum PixelOrientation: String, Hashable, Sendable, CaseIterable {
    /// The canonical presentation orientation: rows top→bottom, columns left→right, no transform.
    case up
    case upMirrored
    case down
    case downMirrored
    case leftMirrored
    case right
    case rightMirrored
    case left
}

/// Validated, immutable pixel dimensions and row layout. All size arithmetic is checked and the
/// validated total byte count is stored (item 1).
public struct PixelDimensions: Hashable, Sendable {
    /// Width in pixels (> 0).
    public let width: Int
    /// Height in pixels (> 0).
    public let height: Int
    /// Bytes per row (>= width * bytesPerPixel). Allows row padding/alignment.
    public let bytesPerRow: Int
    /// The pixel byte format these dimensions describe.
    public let format: PixelByteFormat
    /// The explicit presentation orientation (issue #5). Defaults to the canonical ``PixelOrientation/up``.
    public let orientation: PixelOrientation
    /// The validated total byte count (`height * bytesPerRow`), computed once with checked arithmetic.
    public let requiredByteCount: Int

    /// Bytes per pixel implied by `format` (BGRA8 → 4).
    public var bytesPerPixel: Int {
        switch format {
        case .bgra8: return 4
        }
    }

    public init(
        width: Int, height: Int, bytesPerRow: Int, format: PixelByteFormat,
        orientation: PixelOrientation = .up
    ) throws {
        guard width > 0, height > 0 else {
            throw RenderModelError.malformedDimensions(
                field: "PixelDimensions", width: Int64(width), height: Int64(height))
        }
        let bpp = (format == .bgra8) ? 4 : 4
        // Checked width * bytesPerPixel: Int.max width must throw, not trap (item 1).
        let minimumStride = try RenderCanonicalEncoding.multiply(width, bpp, "PixelDimensions.minimumStride")
        guard bytesPerRow >= minimumStride else {
            throw RenderModelError.malformedDimensions(
                field: "PixelDimensions.bytesPerRow", width: Int64(width), height: Int64(height))
        }
        // Checked height * bytesPerRow → the stored, validated byte count (item 1).
        self.requiredByteCount = try RenderCanonicalEncoding.multiply(
            height, bytesPerRow, "PixelDimensions.requiredByteCount")
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.format = format
        self.orientation = orientation
    }
}

/// A stable identity for a resolved pixel input within a frame's inputs.
public struct PixelInputID: Hashable, Sendable, Comparable {
    public let rawValue: String
    public init(_ rawValue: String) throws {
        guard !rawValue.isEmpty else {
            throw RenderModelError.emptyIdentifier(field: "PixelInputID")
        }
        self.rawValue = rawValue
    }
    public static func < (lhs: PixelInputID, rhs: PixelInputID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Owned, immutable pixel bytes plus their validated descriptor and a domain-scoped content hash
/// (§6 content hashes; §8 readback identity).
public struct ResolvedPixelInput: Hashable, Sendable {
    public let id: PixelInputID
    public let dimensions: PixelDimensions
    /// The owned bytes. `bytes` is a defensive value copy of the caller's data (item 2): `Data` has
    /// value semantics, and the explicit copy below severs any shared backing storage / no-copy view
    /// the caller may have constructed, so later mutation of the source cannot alter this input.
    public let bytes: Data
    /// Lowercase hex SHA-256 over the domain-tagged dimensions metadata and `bytes`
    /// (see ``RenderCanonicalEncoding/pixelContentHash(dimensions:bytes:)``).
    public let contentHash: String

    public init(id: PixelInputID, dimensions: PixelDimensions, bytes: Data) throws {
        guard bytes.count == dimensions.requiredByteCount else {
            throw RenderModelError.pixelByteCountMismatch(
                expected: dimensions.requiredByteCount, actual: bytes.count)
        }
        // Defensive copy: force fresh contiguous backing storage independent of the caller's buffer.
        let owned = Data(bytes)
        self.id = id
        self.dimensions = dimensions
        self.bytes = owned
        self.contentHash = try RenderCanonicalEncoding.pixelContentHash(dimensions: dimensions, bytes: owned)
    }
}
