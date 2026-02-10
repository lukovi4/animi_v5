import Foundation
import zlib

// MARK: - Compiled Package Error

/// Errors that can occur during compiled package loading/writing.
public enum CompiledPackageError: Error {
    case fileNotFound(URL)
    case ioReadFailed(URL)
    case ioWriteFailed(URL)
    case invalidMagic
    case unsupportedNewerFormat(found: UInt16, supported: UInt16)
    case unsupportedOlderFormat(found: UInt16, supported: UInt16)
    case engineMismatch(found: UInt32, expected: UInt32)
    case payloadLengthMismatch
    case payloadDecodeFailed
}

// MARK: - Compiled Package Constants

/// Constants for compiled package format.
public enum CompiledPackageConstants {
    /// Magic bytes: "TVE1" in ASCII
    public static let magicBytes: [UInt8] = [0x54, 0x56, 0x45, 0x31]

    /// Current supported format version
    public static let supportedFormatVersion: UInt16 = 1

    /// Header size for v1 format (16 bytes)
    public static let headerSizeV1: UInt16 = 16
}

// MARK: - Engine Version Hash

/// Computes CRC32 hash of engine version string for compatibility checking.
/// - Parameter version: Engine version string (e.g., "0.1.0")
/// - Returns: CRC32 hash as UInt32
@inline(__always)
public func engineVersionHash(_ version: String) -> UInt32 {
    let data = Data(version.utf8)
    return data.withUnsafeBytes { raw in
        let ptr = raw.bindMemory(to: Bytef.self).baseAddress
        return UInt32(crc32(0, ptr, uInt(data.count)))
    }
}
