import Foundation
import AnimiEngineRenderModel

/// Task-003 / Step-13 — READ-ONLY approved-reference lookup (D5; hard constraints 2/5).
///
/// A normal run MAY read an approved reference for a candidate (keyed by the deterministic `candidateID`)
/// to produce a comparison verdict. It MUST NOT write, create, or update any approved reference: this type
/// has no write path at all. References are stored as deterministic RGBA PNGs (the format
/// `DeterministicPNGEncoder` produces); reading decodes one back to a canonical BGRA8 `RenderedFrame`.
///
/// No reference promotion, no approval schema (D5) — `ReferenceApproval` stays an empty stub.
public struct ReferenceStore: Sendable {

    public enum ReferenceError: Error, Equatable, Sendable {
        case unreadable(candidateID: String, detail: String)
        case malformedPNG(candidateID: String, detail: String)
        case unsupportedPNG(candidateID: String, detail: String)
    }

    /// The read-only approved-reference root. The store NEVER writes under this URL.
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    /// The on-disk path of a candidate's approved reference (whether or not it exists): `references/<id>.png`.
    public func referenceURL(for candidateID: String) -> URL {
        rootURL.appendingPathComponent("references").appendingPathComponent("\(candidateID).png")
    }

    /// Whether an approved reference exists for the candidate.
    public func hasReference(for candidateID: String) -> Bool {
        FileManager.default.fileExists(atPath: referenceURL(for: candidateID).path)
    }

    /// Read + decode the approved reference for `candidateID`, or `nil` if none exists. Decoding handles the
    /// deterministic RGBA8 / stored-DEFLATE PNGs Step 13 produces; any other PNG form is a typed error
    /// (not a silent fallback). The result is a canonical BGRA8 `RenderedFrame`.
    public func reference(for candidateID: String) throws -> RenderedFrame? {
        let url = referenceURL(for: candidateID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw ReferenceError.unreadable(candidateID: candidateID, detail: "\(error)") }
        return try decodeBGRA8Frame(candidateID: candidateID, png: data)
    }

    /// Decode already-read PNG bytes to a canonical BGRA8 `RenderedFrame` (Step-17 promotion integrity check:
    /// verify a candidate PNG's decoded `rawOutputHash` matches its manifest). Same deterministic decoder as
    /// `reference(for:)`; no filesystem read.
    public func decodeForPromotion(png: Data, candidateID: String) throws -> RenderedFrame {
        try decodeBGRA8Frame(candidateID: candidateID, png: png)
    }

    // MARK: - Minimal deterministic PNG decode (RGBA8 / filter 0 / stored or inflated IDAT)

    private func decodeBGRA8Frame(candidateID: String, png: Data) throws -> RenderedFrame {
        let (width, height, rgba) = try PNGReader.decodeRGBA8(png) { reason in
            ReferenceError.malformedPNG(candidateID: candidateID, detail: reason)
        } unsupported: { reason in
            ReferenceError.unsupportedPNG(candidateID: candidateID, detail: reason)
        }
        // RGBA → BGRA (canonical readback order).
        var bgra = [UInt8](repeating: 0, count: width * height * 4)
        var i = 0
        while i < rgba.count {
            bgra[i + 0] = rgba[i + 2]   // B
            bgra[i + 1] = rgba[i + 1]   // G
            bgra[i + 2] = rgba[i + 0]   // R
            bgra[i + 3] = rgba[i + 3]   // A
            i += 4
        }
        let dims = try PixelDimensions(width: width, height: height, bytesPerRow: width * 4,
                                       format: .bgra8, orientation: .up)
        return try RenderedFrame(dimensions: dims, colorContract: .task003, bytes: Data(bgra))
    }
}

/// A minimal, deterministic PNG reader for the format `DeterministicPNGEncoder` produces: 8-bit RGBA
/// (colour type 6), filter type 0 (None), and a zlib IDAT built from **stored (uncompressed) DEFLATE
/// blocks**. Any other PNG form (compressed blocks, other colour type/bit depth/filter, interlace) is a
/// typed `unsupported` error — never a silent fallback. Pure integer parsing; no force-unwrap, no trap.
enum PNGReader {
    static func decodeRGBA8(
        _ png: Data,
        malformed: (String) -> Error,
        unsupported: (String) -> Error
    ) throws -> (width: Int, height: Int, rgba: [UInt8]) {
        let b = [UInt8](png)
        let sig: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard b.count > 8, Array(b[0..<8]) == sig else { throw malformed("bad signature") }

        var i = 8
        var width = 0, height = 0, sawIHDR = false
        var idat = [UInt8]()
        while i + 8 <= b.count {
            let len = beInt(b, i); i += 4
            guard i + 4 <= b.count else { throw malformed("truncated chunk type") }
            let type = String(bytes: b[i..<(i + 4)], encoding: .ascii) ?? ""; i += 4
            guard i + len + 4 <= b.count else { throw malformed("truncated chunk \(type)") }
            let chunk = Array(b[i..<(i + len)]); i += len
            i += 4   // skip CRC (reading our own deterministic output; CRC re-check is not required here)
            switch type {
            case "IHDR":
                guard len == 13 else { throw malformed("IHDR length") }
                width = beInt(chunk, 0); height = beInt(chunk, 4)
                let bitDepth = Int(chunk[8]), colourType = Int(chunk[9])
                let compression = Int(chunk[10]), filterMethod = Int(chunk[11]), interlace = Int(chunk[12])
                guard bitDepth == 8, colourType == 6 else { throw unsupported("bitDepth \(bitDepth)/colourType \(colourType)") }
                guard compression == 0, filterMethod == 0, interlace == 0 else { throw unsupported("compression/filter/interlace") }
                guard width > 0, height > 0 else { throw malformed("non-positive dimensions") }
                sawIHDR = true
            case "IDAT":
                idat.append(contentsOf: chunk)
            case "IEND":
                i = b.count   // done
            default:
                break        // ignore ancillary chunks
            }
        }
        guard sawIHDR else { throw malformed("missing IHDR") }

        let raw = try inflateStored(idat, unsupported: unsupported, malformed: malformed)
        // Unfilter: each row is [filter byte][RGBA × width]; only filter 0 (None) is supported.
        let rowLen = width * 4
        let stride = rowLen + 1
        guard raw.count == stride * height else { throw malformed("raw stream size \(raw.count) != \(stride * height)") }
        var rgba = [UInt8](repeating: 0, count: rowLen * height)
        for y in 0..<height {
            let filter = raw[y * stride]
            guard filter == 0 else { throw unsupported("scanline filter \(filter) != 0") }
            let src = y * stride + 1
            let dst = y * rowLen
            for x in 0..<rowLen { rgba[dst + x] = raw[src + x] }
        }
        return (width, height, rgba)
    }

    /// Inflate a zlib stream consisting only of STORED (BTYPE=00) DEFLATE blocks (what our encoder emits).
    /// A compressed block (BTYPE != 00) is a typed `unsupported` error.
    private static func inflateStored(
        _ zlib: [UInt8], unsupported: (String) -> Error, malformed: (String) -> Error
    ) throws -> [UInt8] {
        guard zlib.count >= 6 else { throw malformed("zlib too short") }
        // 2-byte zlib header, then stored blocks, then 4-byte Adler-32 trailer.
        var p = 2
        var out = [UInt8]()
        var done = false
        while !done {
            guard p < zlib.count - 4 else { throw malformed("zlib block header past end") }
            let header = zlib[p]; p += 1
            let bfinal = (header & 0x01) != 0
            let btype = (header >> 1) & 0x03
            guard btype == 0 else { throw unsupported("DEFLATE BTYPE \(btype) (only stored is supported)") }
            guard p + 4 <= zlib.count - 4 else { throw malformed("stored block len fields past end") }
            let len = Int(zlib[p]) | (Int(zlib[p + 1]) << 8); p += 2
            p += 2   // NLEN (not re-validated for our own output)
            guard p + len <= zlib.count - 4 else { throw malformed("stored block data past end") }
            out.append(contentsOf: zlib[p..<(p + len)]); p += len
            if bfinal { done = true }
        }
        return out
    }

    private static func beInt(_ b: [UInt8], _ off: Int) -> Int {
        (Int(b[off]) << 24) | (Int(b[off + 1]) << 16) | (Int(b[off + 2]) << 8) | Int(b[off + 3])
    }
}
