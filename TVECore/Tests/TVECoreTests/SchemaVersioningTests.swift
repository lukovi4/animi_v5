import XCTest
@testable import TVECore
@testable import TVECompilerCore

/// PR5 Tests: .tve schema versioning and backward compatibility
final class SchemaVersioningTests: XCTestCase {

    // MARK: - Test Resources

    /// URL to compiled.tve in test resources (if available)
    private var compiledTemplateURL: URL? {
        Bundle.module.url(
            forResource: "compiled",
            withExtension: "tve",
            subdirectory: "Resources/example_4blocks"
        )?.deletingLastPathComponent()
    }

    // MARK: - Test Helpers

    /// Writes data to a temp file and returns the folder URL
    private func writeTempTve(_ data: Data) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("compiled.tve")
        try data.write(to: fileURL)
        return tempDir
    }

    /// Creates a .tve header with given parameters (payload data appended separately)
    private func createHeader(
        headerLength: UInt16,
        payloadLength: UInt32,
        engineHash: UInt32,
        schemaVersion: UInt16? = nil
    ) -> Data {
        var data = Data()

        // Magic bytes (4 bytes)
        data.append(contentsOf: CompiledPackageConstants.magicBytes)

        // UInt16 formatVersion = 1 (LE)
        var formatVersion: UInt16 = 1
        data.append(contentsOf: withUnsafeBytes(of: &formatVersion) { Array($0) })

        // UInt16 headerLength (LE)
        var hl = headerLength
        data.append(contentsOf: withUnsafeBytes(of: &hl) { Array($0) })

        // UInt32 payloadLength (LE)
        var pl = payloadLength
        data.append(contentsOf: withUnsafeBytes(of: &pl) { Array($0) })

        // UInt32 engineVersionHash (LE)
        var vh = engineHash
        data.append(contentsOf: withUnsafeBytes(of: &vh) { Array($0) })

        // UInt16 irSchemaVersion (LE) — only if headerLength >= 18
        if let schema = schemaVersion {
            var sv = schema
            data.append(contentsOf: withUnsafeBytes(of: &sv) { Array($0) })
        }

        return data
    }

    /// Loads an existing compiled.tve, modifies its header, and writes to temp location
    private func createModifiedTve(
        headerLength: UInt16,
        engineHash: UInt32? = nil,
        schemaVersion: UInt16? = nil
    ) throws -> URL {
        guard let templateURL = compiledTemplateURL else {
            throw XCTSkip("compiled.tve not found in test resources - run Scripts/compile_templates.sh first")
        }

        let originalData = try Data(contentsOf: templateURL.appendingPathComponent("compiled.tve"))

        // Read original payload (starts at offset determined by original headerLength)
        let originalHeaderLength: UInt16 = originalData.subdata(in: 6..<8).withUnsafeBytes { $0.load(as: UInt16.self) }
        let payloadData = originalData.subdata(in: Int(originalHeaderLength)..<originalData.count)

        // Create new header
        let newEngineHash = engineHash ?? engineVersionHash(TVECore.version)
        let header = createHeader(
            headerLength: headerLength,
            payloadLength: UInt32(payloadData.count),
            engineHash: newEngineHash,
            schemaVersion: schemaVersion
        )

        var newData = header
        newData.append(payloadData)

        return try writeTempTve(newData)
    }

    // MARK: - Test 1: Legacy header (16 bytes) loads with implicit schema=1

    func testLegacyHeader_loadsWithImplicitSchema1() throws {
        // Given: Legacy .tve with headerLength=16 (no irSchemaVersion field)
        let tempDir = try createModifiedTve(headerLength: 16)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let loader = CompiledScenePackageLoader(engineVersion: TVECore.version)

        // When
        let package = try loader.load(from: tempDir)

        // Then: Should load successfully (implicit schema=1)
        XCTAssertNotNil(package.compiled)
    }

    // MARK: - Test 2: New header (18 bytes) loads with schema=1

    func testNewHeader_loadsWithSchema1() throws {
        // Given: New .tve with headerLength=18 and irSchemaVersion=1
        let tempDir = try createModifiedTve(headerLength: 18, schemaVersion: 1)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let loader = CompiledScenePackageLoader(engineVersion: TVECore.version)

        // When
        let package = try loader.load(from: tempDir)

        // Then: Should load successfully
        XCTAssertNotNil(package.compiled)
    }

    // MARK: - Test 3: Unsupported schema version (too old) throws error

    func testUnsupportedSchemaVersion_tooOld_throwsError() throws {
        // Given: .tve with schema=0 (below supported range 1...1)
        let tempDir = try createModifiedTve(headerLength: 18, schemaVersion: 0)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let loader = CompiledScenePackageLoader(engineVersion: TVECore.version)

        // When/Then: Should throw unsupportedSchemaVersion
        XCTAssertThrowsError(try loader.load(from: tempDir)) { error in
            guard case CompiledPackageError.unsupportedSchemaVersion(let found, let supported) = error else {
                XCTFail("Expected unsupportedSchemaVersion error, got \(error)")
                return
            }
            XCTAssertEqual(found, 0)
            XCTAssertEqual(supported, 1...1)
        }
    }

    // MARK: - Test 4: Unsupported schema version (too new) throws error

    func testUnsupportedSchemaVersion_tooNew_throwsError() throws {
        // Given: .tve with schema=999 (above supported range 1...1)
        let tempDir = try createModifiedTve(headerLength: 18, schemaVersion: 999)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let loader = CompiledScenePackageLoader(engineVersion: TVECore.version)

        // When/Then: Should throw unsupportedSchemaVersion
        XCTAssertThrowsError(try loader.load(from: tempDir)) { error in
            guard case CompiledPackageError.unsupportedSchemaVersion(let found, let supported) = error else {
                XCTFail("Expected unsupportedSchemaVersion error, got \(error)")
                return
            }
            XCTAssertEqual(found, 999)
            XCTAssertEqual(supported, 1...1)
        }
    }

    // MARK: - Test 5: Engine hash mismatch is NOT an error

    func testEngineHashMismatch_isNotError() throws {
        // Given: .tve with different engineVersionHash (simulates compiled with older engine)
        let differentHash: UInt32 = 0x12345678
        let tempDir = try createModifiedTve(headerLength: 18, engineHash: differentHash, schemaVersion: 1)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let loader = CompiledScenePackageLoader(engineVersion: TVECore.version)

        // When: Load should NOT throw (engine hash mismatch is now a warning, not error)
        let package = try loader.load(from: tempDir)

        // Then: Should load successfully despite hash mismatch
        XCTAssertNotNil(package.compiled)
    }

    // MARK: - Test 6: Writer produces correct header with schema version

    func testWriter_producesCorrectHeaderWithSchema() throws {
        guard let templateURL = compiledTemplateURL else {
            throw XCTSkip("compiled.tve not found in test resources")
        }

        // Given: Load original compiled scene
        let loader = CompiledScenePackageLoader(engineVersion: TVECore.version)
        let package = try loader.load(from: templateURL)

        // Create payload from loaded scene
        let payload = CompiledScenePayload(
            compiled: package.compiled,
            templateId: package.sceneId,
            templateRevision: 1,
            engineVersion: TVECore.version
        )

        // When: Write to temp file using Writer
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("compiled.tve")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try CompiledScenePackageWriter.write(
            payload: payload,
            to: fileURL,
            engineVersion: TVECore.version
        )

        // Then: Read raw data and verify header
        let data = try Data(contentsOf: fileURL)

        // Magic
        XCTAssertEqual(Array(data[0..<4]), CompiledPackageConstants.magicBytes)

        // Format version = 1
        let formatVersion: UInt16 = data.subdata(in: 4..<6).withUnsafeBytes { $0.load(as: UInt16.self) }
        XCTAssertEqual(formatVersion, 1)

        // Header length = 18
        let headerLength: UInt16 = data.subdata(in: 6..<8).withUnsafeBytes { $0.load(as: UInt16.self) }
        XCTAssertEqual(headerLength, 18)

        // Schema version = 1 at offset 16
        let schemaVersion: UInt16 = data.subdata(in: 16..<18).withUnsafeBytes { $0.load(as: UInt16.self) }
        XCTAssertEqual(schemaVersion, CompiledPackageConstants.currentIRSchemaVersion)
    }
}
