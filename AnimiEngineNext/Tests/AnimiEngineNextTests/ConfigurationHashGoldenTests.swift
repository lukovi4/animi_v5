import XCTest
@testable import AnimiEngineNext

/// Hash-stability and golden-hash tests (Task-001 acceptance #4).
final class ConfigurationHashGoldenTests: XCTestCase {

    /// Pinned SHA-256 of the canonical bytes of `ConfigurationTests.referenceConfiguration()`.
    /// Any silent change to canonical encoding or the reference config fails CI.
    private static let goldenHash = "cf46cb5ef74dd1618644203675893929c9c42985cf6c2e172767216aa949a2fe"

    func testIdenticalConfigsProduceIdenticalHash() {
        let a = ConfigurationTests.referenceConfiguration()
        let b = ConfigurationTests.referenceConfiguration()
        XCTAssertEqual(ConfigurationHash.sha256Hex(of: a), ConfigurationHash.sha256Hex(of: b))
    }

    func testKeyOrderDoesNotAffectHash() {
        // The canonical form sorts keys, so two equal configs hash identically regardless of how
        // their fields were constructed. (Field declaration order in `referenceConfiguration()`
        // does not match canonical/sorted order — this asserts that independence.)
        let config = ConfigurationTests.referenceConfiguration()
        let bytes = CanonicalEncoding.canonicalBytes(of: config)
        let string = String(decoding: bytes, as: UTF8.self)
        // Top-level keys must appear in sorted order in the canonical bytes.
        let cacheIndex = string.range(of: "\"cache\"")!.lowerBound
        let previewIndex = string.range(of: "\"preview\"")!.lowerBound
        XCTAssertLessThan(cacheIndex, previewIndex, "canonical keys must be sorted")
    }

    func testValueChangeChangesHash() {
        var changed = ConfigurationTests.referenceConfiguration()
        changed.projectFrameRate = 24
        XCTAssertNotEqual(
            ConfigurationHash.sha256Hex(of: ConfigurationTests.referenceConfiguration()),
            ConfigurationHash.sha256Hex(of: changed)
        )
    }

    func testGoldenHashMatchesPinnedDigest() {
        let actual = ConfigurationHash.sha256Hex(of: ConfigurationTests.referenceConfiguration())
        XCTAssertEqual(actual, Self.goldenHash, "golden hash drift — actual: \(actual)")
    }
}
