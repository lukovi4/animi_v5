import Foundation

/// PR-F §6.1: Pure helper for resolving the render quad geometry for an asset.
///
/// Encapsulates the 4-tier priority used by `drawImage(...)` in `MetalRenderer+Execute.swift`:
/// 1. `videoOrientedSize` (video track metadata)
/// 2. `displaySize` (user media display size from `AssetDisplaySizeProvider`)
/// 3. `assetSize` (template asset size from Lottie compilation)
/// 4. `textureSize` (actual GPU texture dimensions as fallback)
public enum AssetRenderGeometryResolver {

    /// Source that was used to determine the geometry.
    public enum Source: Equatable, Sendable {
        case videoOrientedSize
        case displaySize
        case assetSize
        case textureSize
    }

    /// Resolved geometry result.
    public struct Result: Equatable, Sendable {
        public let width: Double
        public let height: Double
        public let source: Source
    }

    /// Resolves quad geometry using the canonical 4-tier priority.
    public static func resolve(
        videoOrientedSize: CGSize?,
        displaySize: CGSize?,
        assetSize: AssetSize?,
        textureWidth: Int,
        textureHeight: Int
    ) -> Result {
        if let videoOrientedSize {
            return Result(width: videoOrientedSize.width, height: videoOrientedSize.height, source: .videoOrientedSize)
        }
        if let displaySize {
            return Result(width: displaySize.width, height: displaySize.height, source: .displaySize)
        }
        if let assetSize {
            return Result(width: assetSize.width, height: assetSize.height, source: .assetSize)
        }
        return Result(width: Double(textureWidth), height: Double(textureHeight), source: .textureSize)
    }
}
