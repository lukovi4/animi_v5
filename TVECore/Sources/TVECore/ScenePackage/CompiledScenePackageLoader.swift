import Foundation

// MARK: - Compiled Scene Package

/// A loaded compiled scene package with its root URL.
public struct CompiledScenePackage {
    /// The compiled scene (runtime-ready)
    public let compiled: CompiledScene

    /// Root URL of the package folder (for asset resolution)
    public let rootURL: URL

    /// Scene identifier (from templateId in payload)
    public let sceneId: String?

    public init(compiled: CompiledScene, rootURL: URL, sceneId: String?) {
        self.compiled = compiled
        self.rootURL = rootURL
        self.sceneId = sceneId
    }
}

// MARK: - Compiled Scene Package Loader

/// Loads compiled scene packages from .tve files.
public final class CompiledScenePackageLoader {
    private let engineVersion: String

    /// Creates a loader with the specified engine version for compatibility checking.
    /// - Parameter engineVersion: Current engine version (e.g., TVECore.version)
    public init(engineVersion: String) {
        self.engineVersion = engineVersion
    }

    /// Loads a compiled scene package from a folder containing compiled.tve.
    /// - Parameter rootURL: Root folder URL containing compiled.tve
    /// - Returns: Loaded compiled scene package
    /// - Throws: `CompiledPackageError` on validation or I/O errors
    public func load(from rootURL: URL) throws -> CompiledScenePackage {
        let fileURL = rootURL.appendingPathComponent("compiled.tve", isDirectory: false)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CompiledPackageError.fileNotFound(fileURL)
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw CompiledPackageError.ioReadFailed(fileURL)
        }

        // Header minimal validation
        guard data.count >= Int(CompiledPackageConstants.headerSizeV1) else {
            throw CompiledPackageError.payloadLengthMismatch
        }

        // Validate magic bytes
        let magic = data.subdata(in: 0..<4)
        guard Array(magic) == CompiledPackageConstants.magicBytes else {
            throw CompiledPackageError.invalidMagic
        }

        // Validate format version
        let formatVersion: UInt16 = data.readLE(at: 4)
        let supported = CompiledPackageConstants.supportedFormatVersion
        if formatVersion > supported {
            throw CompiledPackageError.unsupportedNewerFormat(found: formatVersion, supported: supported)
        }
        if formatVersion < supported {
            throw CompiledPackageError.unsupportedOlderFormat(found: formatVersion, supported: supported)
        }

        // Read header fields
        let headerLength: UInt16 = data.readLE(at: 6)
        guard headerLength >= CompiledPackageConstants.headerSizeV1 else {
            throw CompiledPackageError.payloadLengthMismatch
        }

        let payloadLength: UInt32 = data.readLE(at: 8)

        // Validate engine version hash
        let foundHash: UInt32 = data.readLE(at: 12)
        let expectedHash = engineVersionHash(engineVersion)
        guard foundHash == expectedHash else {
            throw CompiledPackageError.engineMismatch(found: foundHash, expected: expectedHash)
        }

        // Extract and decode payload
        let payloadStart = Int(headerLength)
        let payloadEnd = payloadStart + Int(payloadLength)
        guard payloadEnd <= data.count else {
            throw CompiledPackageError.payloadLengthMismatch
        }

        let payloadData = data.subdata(in: payloadStart..<payloadEnd)

        let decoder = JSONDecoder()
        let payload: CompiledScenePayload
        do {
            payload = try decoder.decode(CompiledScenePayload.self, from: payloadData)
        } catch {
            throw CompiledPackageError.payloadDecodeFailed
        }

        return CompiledScenePackage(
            compiled: payload.compiled,
            rootURL: rootURL,
            sceneId: payload.templateId
        )
    }
}

// MARK: - Data Extension (Little-Endian Reading)

private extension Data {
    /// Reads a fixed-width integer in little-endian byte order at the given offset.
    func readLE<T: FixedWidthInteger>(at offset: Int) -> T {
        let size = MemoryLayout<T>.size
        return self.subdata(in: offset..<(offset + size)).withUnsafeBytes { raw in
            raw.load(as: T.self).littleEndian
        }
    }
}
