import Foundation
import TVECore

// MARK: - Compiled Scene Package Writer

/// Writes compiled scene packages to .tve files.
public enum CompiledScenePackageWriter {

    /// Writes a compiled scene payload to a .tve file.
    /// - Parameters:
    ///   - payload: The compiled scene payload to write
    ///   - fileURL: Destination file URL (should end with .tve)
    ///   - engineVersion: Engine version string for hash computation
    /// - Throws: `CompiledPackageError.ioWriteFailed` on I/O errors
    public static func write(
        payload: CompiledScenePayload,
        to fileURL: URL,
        engineVersion: String
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [] // Compact JSON for release

        let payloadData = try encoder.encode(payload)

        let formatVersion = CompiledPackageConstants.supportedFormatVersion
        let headerLength = CompiledPackageConstants.headerSizeV1
        let payloadLength = UInt32(payloadData.count)
        let versionHash = engineVersionHash(engineVersion)

        var data = Data()
        data.reserveCapacity(Int(headerLength) + payloadData.count)

        // Magic bytes (4 bytes)
        data.append(contentsOf: CompiledPackageConstants.magicBytes)

        // UInt16 compiledFormatVersion (LE)
        data.appendLE(formatVersion)

        // UInt16 headerLength (LE) — v1 = 16
        data.appendLE(headerLength)

        // UInt32 payloadLength (LE)
        data.appendLE(payloadLength)

        // UInt32 engineVersionHash (LE)
        data.appendLE(versionHash)

        // JSON payload
        data.append(payloadData)

        do {
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw CompiledPackageError.ioWriteFailed(fileURL)
        }
    }
}

// MARK: - Data Extension (Little-Endian Writing)

private extension Data {
    /// Appends a fixed-width integer in little-endian byte order.
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { raw in
            append(contentsOf: raw)
        }
    }
}
