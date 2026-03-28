import Foundation
import simd

/// Static metadata for a video track's native orientation and size.
/// Computed once at provider prepare time, never changes.
public struct VideoPresentationInfo: Equatable, Sendable {
    /// Raw track size before applying preferredTransform
    public let rawTrackSize: CGSize
    /// Track's preferredTransform from AVAssetTrack
    public let preferredTransform: CGAffineTransform
    /// Size after applying preferredTransform (what the user sees)
    public let orientedSize: CGSize
    /// 4×4 UV transform matrix for GPU sampling (maps oriented quad UVs → raw texture UVs)
    public let uvTransform: simd_float4x4

    public init(rawTrackSize: CGSize, preferredTransform: CGAffineTransform) {
        self.rawTrackSize = rawTrackSize
        self.preferredTransform = preferredTransform
        self.orientedSize = CGRect(origin: .zero, size: rawTrackSize)
            .applying(preferredTransform).standardized.size
        self.uvTransform = Self.computeUVTransform(
            rawSize: rawTrackSize,
            transform: preferredTransform
        )
    }

    /// Computes a 4×4 UV-space transform for sampling a raw video texture.
    ///
    /// The quad is sized to the **oriented** image (what the user sees), so quad UVs
    /// represent positions in oriented space. The texture contains **raw** pixels
    /// (before preferredTransform). This method computes the inverse mapping:
    ///
    ///     rawUV = S_raw⁻¹ · T⁻¹ · S_oriented · quadUV
    ///
    /// where T is the pixel-space preferredTransform (raw → oriented),
    /// S_raw = diag(rawW, rawH), S_oriented = diag(orientedW, orientedH).
    ///
    /// Apple video tracks use CGAffineTransform to encode orientation:
    /// - 0° (landscape):   identity                               → UV identity
    /// - 90° CW (portrait): a=0,b=1,c=-1,d=0,tx=h,ty=0           → (u,v)→(v, 1-u)
    /// - 180°:              a=-1,b=0,c=0,d=-1,tx=w,ty=h           → (u,v)→(1-u, 1-v)
    /// - 90° CCW:           a=0,b=-1,c=1,d=0,tx=0,ty=w            → (u,v)→(1-v, u)
    private static func computeUVTransform(
        rawSize: CGSize,
        transform: CGAffineTransform
    ) -> simd_float4x4 {
        let rw = Float(rawSize.width)
        let rh = Float(rawSize.height)

        // Guard against degenerate sizes
        guard rw > 0 && rh > 0 else {
            return matrix_identity_float4x4
        }

        // Compute oriented size (matches orientedSize property)
        let orientedRect = CGRect(origin: .zero, size: rawSize)
            .applying(transform).standardized
        let ow = Float(orientedRect.width)
        let oh = Float(orientedRect.height)

        guard ow > 0 && oh > 0 else {
            return matrix_identity_float4x4
        }

        // Invert the pixel-space transform: T maps raw→oriented, T⁻¹ maps oriented→raw
        let inv = transform.inverted()
        let ia = Float(inv.a)
        let ib = Float(inv.b)
        let ic = Float(inv.c)
        let id = Float(inv.d)
        let itx = Float(inv.tx)
        let ity = Float(inv.ty)

        // Full UV transform = S_raw⁻¹ · T⁻¹ · S_oriented
        //
        // S_oriented scales UV [0,1] → oriented pixels:
        //   | ow  0  |
        //   | 0   oh |
        //
        // T⁻¹ maps oriented pixels → raw pixels:
        //   | ia  ic  itx |
        //   | ib  id  ity |
        //
        // S_raw⁻¹ scales raw pixels → UV [0,1]:
        //   | 1/rw  0    |
        //   | 0     1/rh |
        //
        // Combined 2D affine:
        //   a' = ia * ow / rw,  c' = ic * oh / rw,  tx' = itx / rw
        //   b' = ib * ow / rh,  d' = id * oh / rh,  ty' = ity / rh

        let a2 = ia * ow / rw
        let b2 = ib * ow / rh
        let c2 = ic * oh / rw
        let d2 = id * oh / rh
        let tx2 = itx / rw
        let ty2 = ity / rh

        // Build column-major 4×4 matrix:
        // | a'  c'  0  tx' |
        // | b'  d'  0  ty' |
        // | 0   0   1  0   |
        // | 0   0   0  1   |
        return simd_float4x4(columns: (
            SIMD4<Float>(a2,  b2,  0, 0),   // column 0
            SIMD4<Float>(c2,  d2,  0, 0),   // column 1
            SIMD4<Float>(0,   0,   1, 0),   // column 2
            SIMD4<Float>(tx2, ty2, 0, 1)    // column 3
        ))
    }
}

// MARK: - Equatable for CGAffineTransform comparison

extension VideoPresentationInfo {
    public static func == (lhs: VideoPresentationInfo, rhs: VideoPresentationInfo) -> Bool {
        lhs.rawTrackSize == rhs.rawTrackSize
            && lhs.preferredTransform == rhs.preferredTransform
            && lhs.orientedSize == rhs.orientedSize
            && lhs.uvTransform == rhs.uvTransform
    }
}

// MARK: - Asset Presentation Info Protocols

/// Read-only access to per-asset video presentation metadata.
public protocol AssetPresentationInfoProvider {
    func presentationInfo(for assetId: String) -> VideoPresentationInfo?
}

/// Mutable access to per-asset video presentation metadata.
public protocol MutableAssetPresentationInfoProvider: AssetPresentationInfoProvider {
    func setPresentationInfo(_ info: VideoPresentationInfo, for assetId: String)
    func removePresentationInfo(for assetId: String)
}
