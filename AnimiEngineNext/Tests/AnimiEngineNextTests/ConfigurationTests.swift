import XCTest
@testable import AnimiEngineNext

/// Strict-decode and validation tests for ``EngineConfiguration`` (Task-001 acceptance #8).
final class ConfigurationTests: XCTestCase {

    // MARK: - Reference config & JSON

    /// A fixed reference configuration used across configuration/hash tests.
    static func referenceConfiguration() -> EngineConfiguration {
        EngineConfiguration(
            schemaVersion: 1,
            projectFrameRate: 30,
            preview: PreviewConfiguration(frameRateLadder: [60, 30, 24]),
            decoder: DecoderConfiguration(backend: "videoToolbox", poolLimit: 4),
            proxy: ProxyConfiguration(profiles: [
                ProxyProfile(name: "low", maxDimension: 540),
                ProxyProfile(name: "high", maxDimension: 1080)
            ]),
            cache: CacheConfiguration(frameCacheBudgetMiB: 256, diskProxyBudgetMiB: 2048),
            renderQuality: RenderQualityConfiguration(profiles: [
                RenderQualityProfile(name: "draft", scalePercent: 50),
                RenderQualityProfile(name: "final", scalePercent: 100)
            ]),
            memory: MemoryConfiguration(softLimitMiB: 512, hardLimitMiB: 1024),
            export: ExportConfiguration(profiles: [
                ExportProfile(name: "h264-1080", frameRate: 30, bitrate: 12_000_000)
            ]),
            diagnostics: DiagnosticsConfiguration(samplingPercent: 100, output: "ndjson")
        )
    }

    /// Strict JSON for the reference config (well-formed, no unknown fields).
    static let validJSON = """
    {
      "schemaVersion": 1,
      "projectFrameRate": 30,
      "preview": { "frameRateLadder": [60, 30, 24] },
      "decoder": { "backend": "videoToolbox", "poolLimit": 4 },
      "proxy": { "profiles": [
        { "name": "low", "maxDimension": 540 },
        { "name": "high", "maxDimension": 1080 }
      ] },
      "cache": { "frameCacheBudgetMiB": 256, "diskProxyBudgetMiB": 2048 },
      "renderQuality": { "profiles": [
        { "name": "draft", "scalePercent": 50 },
        { "name": "final", "scalePercent": 100 }
      ] },
      "memory": { "softLimitMiB": 512, "hardLimitMiB": 1024 },
      "export": { "profiles": [
        { "name": "h264-1080", "frameRate": 30, "bitrate": 12000000 }
      ] },
      "diagnostics": { "samplingPercent": 100, "output": "ndjson" }
    }
    """

    private func decode(_ json: String) throws -> EngineConfiguration {
        try ConfigurationDecoder().decode(Data(json.utf8))
    }

    // MARK: - Happy path

    func testDecodesValidConfiguration() throws {
        let config = try decode(Self.validJSON)
        XCTAssertEqual(config, Self.referenceConfiguration())
    }

    // MARK: - Unknown fields (any depth)

    func testRejectsUnknownTopLevelField() throws {
        let json = Self.validJSON.replacingOccurrences(
            of: "\"projectFrameRate\": 30,",
            with: "\"projectFrameRate\": 30, \"mystery\": true,"
        )
        XCTAssertThrowsError(try decode(json)) { error in
            XCTAssertEqual(error as? ConfigurationError, .unknownField(path: "mystery"))
        }
    }

    func testRejectsUnknownNestedField() throws {
        let json = Self.validJSON.replacingOccurrences(
            of: "\"backend\": \"videoToolbox\",",
            with: "\"backend\": \"videoToolbox\", \"turbo\": 1,"
        )
        XCTAssertThrowsError(try decode(json)) { error in
            XCTAssertEqual(error as? ConfigurationError, .unknownField(path: "decoder.turbo"))
        }
    }

    func testRejectsUnknownFieldInsideArrayOfObjects() throws {
        let json = Self.validJSON.replacingOccurrences(
            of: "{ \"name\": \"low\", \"maxDimension\": 540 }",
            with: "{ \"name\": \"low\", \"maxDimension\": 540, \"weird\": 0 }"
        )
        XCTAssertThrowsError(try decode(json)) { error in
            XCTAssertEqual(error as? ConfigurationError, .unknownField(path: "proxy.profiles[0].weird"))
        }
    }

    // MARK: - Range validation

    func testRejectsOutOfRangeValue() throws {
        let json = Self.validJSON.replacingOccurrences(
            of: "\"samplingPercent\": 100",
            with: "\"samplingPercent\": 250"
        )
        XCTAssertThrowsError(try decode(json)) { error in
            guard case .outOfRange(let path, _)? = error as? ConfigurationError else {
                return XCTFail("expected outOfRange, got \(error)")
            }
            XCTAssertEqual(path, "diagnostics.samplingPercent")
        }
    }

    func testRejectsNegativeProjectFrameRate() throws {
        let json = Self.validJSON.replacingOccurrences(
            of: "\"projectFrameRate\": 30",
            with: "\"projectFrameRate\": -1"
        )
        XCTAssertThrowsError(try decode(json)) { error in
            guard case .outOfRange(let path, _)? = error as? ConfigurationError else {
                return XCTFail("expected outOfRange, got \(error)")
            }
            XCTAssertEqual(path, "projectFrameRate")
        }
    }

    // MARK: - Schema version

    func testRejectsUnsupportedSchemaVersion() throws {
        let json = Self.validJSON.replacingOccurrences(
            of: "\"schemaVersion\": 1",
            with: "\"schemaVersion\": 999"
        )
        XCTAssertThrowsError(try decode(json)) { error in
            XCTAssertEqual(
                error as? ConfigurationError,
                .unsupportedSchema(found: 999, supported: EngineConfiguration.supportedSchemaVersion)
            )
        }
    }
}
