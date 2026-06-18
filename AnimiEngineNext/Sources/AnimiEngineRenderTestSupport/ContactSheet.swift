import Foundation
import AnimiEngineRenderModel

/// Task-003 / Step-13 — a deterministic contact sheet: a grid of (candidate | reference | diff) tiles,
/// one row per candidate, in candidate order. Pure function of its inputs (no timestamp, no random
/// layout). Encoded with the deterministic PNG encoder so identical inputs → identical bytes.
public enum ContactSheet {

    public enum ContactSheetError: Error, Equatable, Sendable {
        case empty
        case tileDimensionMismatch(detail: String)
        case dimensionOverflow(detail: String)
    }

    /// One contact-sheet row: the candidate frame, an optional reference snapshot, an optional diff. All
    /// present frames must share the candidate's dimensions.
    public struct Row: Sendable {
        public let candidate: RenderedFrame
        public let reference: RenderedFrame?
        public let diffBGRA8: Data?     // tightly packed BGRA8, candidate-sized, or nil
        public init(candidate: RenderedFrame, reference: RenderedFrame?, diffBGRA8: Data?) {
            self.candidate = candidate; self.reference = reference; self.diffBGRA8 = diffBGRA8
        }
    }

    /// Fixed layout constants (deterministic).
    public static let columns = 3            // candidate | reference | diff
    public static let gutter = 2             // transparent gutter pixels between tiles/rows
    /// Maximum thumbnail dimension per tile. Full-resolution candidate PNGs are the real evidence; the
    /// contact sheet is a bounded visual overview, so each tile is downscaled to fit within
    /// `maxThumbnailDimension`² via deterministic nearest-neighbor sampling (exact integer; byte-stable).
    public static let maxThumbnailDimension = 64

    /// A downscaled tile: tight BGRA8 thumbnail + its dimensions.
    private struct Thumb { let bgra8: [UInt8]; let w: Int; let h: Int }

    /// Deterministic nearest-neighbor downscale of a tight BGRA8 source to fit within
    /// `maxThumbnailDimension`². Source pixels are read at `floor(dstX · srcW / dstW)` (exact integer).
    private static func thumbnail(bytes: [UInt8], srcW: Int, srcH: Int, srcStride: Int) -> Thumb {
        let maxDim = maxThumbnailDimension
        if srcW <= maxDim && srcH <= maxDim {
            // Already small: repack tight (no scaling).
            var out = [UInt8](repeating: 0, count: srcW * srcH * 4)
            for y in 0..<srcH { for i in 0..<(srcW * 4) { out[y * srcW * 4 + i] = bytes[y * srcStride + i] } }
            return Thumb(bgra8: out, w: srcW, h: srcH)
        }
        // Scale the longer side to maxDim, preserving aspect (integer, deterministic, >= 1).
        let dstW = srcW >= srcH ? maxDim : max(1, srcW * maxDim / srcH)
        let dstH = srcH >= srcW ? maxDim : max(1, srcH * maxDim / srcW)
        var out = [UInt8](repeating: 0, count: dstW * dstH * 4)
        for dy in 0..<dstH {
            let sy = dy * srcH / dstH
            for dx in 0..<dstW {
                let sx = dx * srcW / dstW
                let s = sy * srcStride + sx * 4
                let d = (dy * dstW + dx) * 4
                out[d + 0] = bytes[s + 0]; out[d + 1] = bytes[s + 1]; out[d + 2] = bytes[s + 2]; out[d + 3] = bytes[s + 3]
            }
        }
        return Thumb(bgra8: out, w: dstW, h: dstH)
    }

    /// Build the contact-sheet PNG. Rows may have DIFFERENT tile sizes (a group can mix differently-sized
    /// candidates, e.g. structural fixtures): each row is laid out at its own candidate dimensions, rows
    /// stack top-to-bottom with a gutter, and the sheet width is the widest row (3 columns of that row's
    /// tile width). A row's reference (if any) must match that row's candidate dimensions.
    public static func encodePNG(rows: [Row]) throws -> Data {
        guard !rows.isEmpty else { throw ContactSheetError.empty }
        for (i, row) in rows.enumerated() {
            if let ref = row.reference,
               ref.dimensions.width != row.candidate.dimensions.width || ref.dimensions.height != row.candidate.dimensions.height {
                throw ContactSheetError.tileDimensionMismatch(detail: "row \(i) reference tile size differs from its candidate")
            }
        }
        // Downscale each row's tiles to bounded thumbnails (deterministic). The candidate's thumbnail
        // dimensions define the row tile size; reference/diff share the candidate's dimensions.
        struct RowThumbs { let cand: Thumb; let ref: Thumb?; let diff: Thumb?; let tw: Int; let th: Int }
        var rowThumbs: [RowThumbs] = []
        for row in rows {
            let cw = row.candidate.dimensions.width, ch = row.candidate.dimensions.height
            let cStride = row.candidate.dimensions.bytesPerRow
            let cand = thumbnail(bytes: [UInt8](row.candidate.bytes), srcW: cw, srcH: ch, srcStride: cStride)
            let ref = row.reference.map { thumbnail(bytes: [UInt8]($0.bytes), srcW: cw, srcH: ch, srcStride: $0.dimensions.bytesPerRow) }
            let diff = row.diffBGRA8.map { thumbnail(bytes: [UInt8]($0), srcW: cw, srcH: ch, srcStride: cw * 4) }
            rowThumbs.append(RowThumbs(cand: cand, ref: ref, diff: diff, tw: cand.w, th: cand.h))
        }
        // Sheet width = widest (3·tileW + 2·gutter); height = sum of row heights + gutters.
        var sheetW = 0, sheetH = 0
        for (i, rt) in rowThumbs.enumerated() {
            sheetW = max(sheetW, Self.columns * rt.tw + (Self.columns - 1) * Self.gutter)
            sheetH += rt.th
            if i < rowThumbs.count - 1 { sheetH += Self.gutter }
        }
        guard sheetW > 0, sheetH > 0, sheetW <= 1 << 16, sheetH <= 1 << 16 else {
            throw ContactSheetError.dimensionOverflow(detail: "sheet \(sheetW)x\(sheetH)")
        }
        let stride = sheetW * 4
        var sheet = [UInt8](repeating: 0, count: stride * sheetH)   // transparent background

        var originY = 0
        for rt in rowThumbs {
            blit(frameBytes: rt.cand.bgra8, srcStride: rt.tw * 4, tileW: rt.tw, tileH: rt.th, into: &sheet, sheetStride: stride, originX: 0, originY: originY)
            if let ref = rt.ref {
                blit(frameBytes: ref.bgra8, srcStride: rt.tw * 4, tileW: rt.tw, tileH: rt.th, into: &sheet, sheetStride: stride, originX: rt.tw + Self.gutter, originY: originY)
            }
            if let diff = rt.diff {
                blit(frameBytes: diff.bgra8, srcStride: rt.tw * 4, tileW: rt.tw, tileH: rt.th, into: &sheet, sheetStride: stride, originX: 2 * (rt.tw + Self.gutter), originY: originY)
            }
            originY += rt.th + Self.gutter
        }
        return try DeterministicPNGEncoder.encodeBGRA8(bytes: Data(sheet), width: sheetW, height: sheetH, bytesPerRow: stride)
    }

    /// Copy a tile (BGRA8) into the sheet at (originX, originY).
    private static func blit(frameBytes: [UInt8], srcStride: Int, tileW: Int, tileH: Int,
                             into sheet: inout [UInt8], sheetStride: Int, originX: Int, originY: Int) {
        for y in 0..<tileH {
            let src = y * srcStride
            let dst = (originY + y) * sheetStride + originX * 4
            for i in 0..<(tileW * 4) { sheet[dst + i] = frameBytes[src + i] }
        }
    }
}
