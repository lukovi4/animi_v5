import Foundation
import AnimiEngineRenderModel

/// Task-003 / Step-13 (D1) — a self-contained, deterministic PNG encoder.
///
/// Encodes a canonical BGRA8 frame (`RenderedFrame.bytes`) to a valid 8-bit RGBA PNG using only pure
/// Swift integer arithmetic: a fixed scanline filter (type 0 = None), **stored (uncompressed) DEFLATE
/// blocks**, a hand-computed Adler-32 (zlib trailer) and CRC-32 (per chunk). It deliberately does NOT use
/// CoreGraphics/ImageIO (whose output is not byte-stable across OS/SDK versions), so identical pixel bytes
/// always produce byte-identical PNG output — the property the transactional evidence system relies on.
///
/// The output is larger than a compressed PNG (stored blocks add ~5 bytes per 65 535-byte chunk) but is a
/// valid, viewable PNG and is fully deterministic. No `Float`/`Double`, no force-unwrap, no `try?`, no trap.
public enum DeterministicPNGEncoder {

    /// Typed encode failures (D6).
    public enum PNGEncodeError: Error, Equatable, Sendable {
        case unsupportedFormat(detail: String)
        case dimensionByteMismatch(width: Int, height: Int, expectedBytes: Int, actualBytes: Int)
        case dimensionOverflow(detail: String)
    }

    /// Encode a `RenderedFrame` (canonical BGRA8, 4 bytes/pixel) into deterministic PNG bytes.
    public static func encode(_ frame: RenderedFrame) throws -> Data {
        let w = frame.dimensions.width
        let h = frame.dimensions.height
        guard frame.dimensions.format == .bgra8 else {
            throw PNGEncodeError.unsupportedFormat(detail: "format \(frame.dimensions.format) != bgra8")
        }
        return try encodeBGRA8(bytes: frame.bytes, width: w, height: h, bytesPerRow: frame.dimensions.bytesPerRow)
    }

    /// Encode raw BGRA8 bytes (premultiplied sRGB, the canonical readback layout) into PNG bytes. `bytes`
    /// is `bytesPerRow * height`; each pixel is B,G,R,A. Channels are reordered to R,G,B,A for PNG.
    public static func encodeBGRA8(bytes: Data, width: Int, height: Int, bytesPerRow: Int) throws -> Data {
        guard width > 0, height > 0 else {
            throw PNGEncodeError.dimensionByteMismatch(width: width, height: height, expectedBytes: 0, actualBytes: bytes.count)
        }
        // Rows are tightly packed at 4 bytes/pixel in the canonical readback; tolerate a wider bytesPerRow.
        guard bytesPerRow >= width * 4 else {
            throw PNGEncodeError.dimensionByteMismatch(width: width, height: height, expectedBytes: width * 4, actualBytes: bytesPerRow)
        }
        guard bytes.count >= bytesPerRow * height else {
            throw PNGEncodeError.dimensionByteMismatch(width: width, height: height, expectedBytes: bytesPerRow * height, actualBytes: bytes.count)
        }

        let src = [UInt8](bytes)
        // Raw image stream = per-row [filter byte 0][R,G,B,A × width]. Build it once.
        let rowStride = width * 4 + 1
        var raw = [UInt8](); raw.reserveCapacity(rowStride * height)
        for y in 0..<height {
            raw.append(0)   // filter type 0 (None)
            let rowStart = y * bytesPerRow
            var x = 0
            while x < width {
                let p = rowStart + x * 4
                let b = src[p + 0], g = src[p + 1], r = src[p + 2], a = src[p + 3]
                raw.append(r); raw.append(g); raw.append(b); raw.append(a)   // BGRA → RGBA
                x += 1
            }
        }

        var png = [UInt8]()
        png.append(contentsOf: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])   // PNG signature

        // IHDR: width, height, bit depth 8, colour type 6 (RGBA), compression 0, filter 0, interlace 0.
        guard let w32 = UInt32(exactly: width), let h32 = UInt32(exactly: height) else {
            throw PNGEncodeError.dimensionOverflow(detail: "width/height exceed UInt32")
        }
        var ihdr = [UInt8]()
        ihdr.append(contentsOf: be32(w32)); ihdr.append(contentsOf: be32(h32))
        ihdr.append(8); ihdr.append(6); ihdr.append(0); ihdr.append(0); ihdr.append(0)
        appendChunk(&png, type: "IHDR", data: ihdr)

        // IDAT: zlib stream = 2-byte header (0x78, 0x01) + stored DEFLATE blocks of `raw` + Adler-32.
        let idat = try zlibStored(raw)
        appendChunk(&png, type: "IDAT", data: idat)

        appendChunk(&png, type: "IEND", data: [])
        return Data(png)
    }

    // MARK: - zlib (stored blocks) + Adler-32

    /// A zlib stream wrapping `data` as STORED (uncompressed) DEFLATE blocks — deterministic and trivial.
    private static func zlibStored(_ data: [UInt8]) throws -> [UInt8] {
        var out = [UInt8]()
        out.append(0x78); out.append(0x01)   // zlib header (CM=8, CINFO=7; FLEVEL fastest, FCHECK valid)
        // Stored blocks: each block max 65 535 bytes. Header: 1 byte (BFINAL bit0 + BTYPE 00), then LEN
        // (2 bytes LE), NLEN (2 bytes LE = ~LEN), then the literal bytes.
        let maxBlock = 65535
        var i = 0
        if data.isEmpty {
            out.append(0x01)                     // BFINAL=1, BTYPE=00
            out.append(contentsOf: le16(0)); out.append(contentsOf: le16(0xFFFF))
        } else {
            while i < data.count {
                let remaining = data.count - i
                let len = min(maxBlock, remaining)
                let isFinal = (i + len) >= data.count
                out.append(isFinal ? 0x01 : 0x00)
                out.append(contentsOf: le16(UInt16(len)))
                out.append(contentsOf: le16(UInt16(len ^ 0xFFFF)))
                out.append(contentsOf: data[i..<(i + len)])
                i += len
            }
        }
        out.append(contentsOf: be32(adler32(data)))
        return out
    }

    private static func adler32(_ data: [UInt8]) -> UInt32 {
        let mod: UInt32 = 65521
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % mod
            b = (b + a) % mod
        }
        return (b << 16) | a
    }

    // MARK: - PNG chunk + CRC-32

    private static func appendChunk(_ png: inout [UInt8], type: String, data: [UInt8]) {
        let typeBytes = Array(type.utf8)
        png.append(contentsOf: be32(UInt32(data.count)))
        png.append(contentsOf: typeBytes)
        png.append(contentsOf: data)
        var crcInput = typeBytes; crcInput.append(contentsOf: data)
        png.append(contentsOf: be32(crc32(crcInput)))
    }

    private static let crcTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for n in 0..<256 {
            var c = UInt32(n)
            for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
            table[n] = c
        }
        return table
    }()

    private static func crc32(_ data: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }

    // MARK: - Big/little-endian byte helpers

    private static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
    private static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private static func le16(_ v: Int) -> [UInt8] { le16(UInt16(v & 0xFFFF)) }
}
