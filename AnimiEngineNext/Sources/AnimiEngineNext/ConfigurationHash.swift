import Foundation
import CryptoKit

/// Stable, reproducible hash of an ``EngineConfiguration`` (decision **D-109**).
///
/// The hash is **SHA-256 over the canonical bytes** produced by `CanonicalEncoding`. Because the
/// canonical form has sorted keys and fixed number formatting, the digest is identical for two
/// configurations that differ only in key order, and changes whenever any value changes.
///
/// Swift's `Hasher` and any `quantizedHash` approach are **explicitly forbidden** here: they are
/// not portable or reproducible across runs and processes (Task-001 plan, "Hashing").
public enum ConfigurationHash {
    /// The lowercase hex SHA-256 digest of already-canonical bytes.
    ///
    /// This is the **single** hashing implementation. It is used both for the in-memory canonical
    /// bytes of a configuration and for the bytes read back from `engine-config.json` during
    /// evidence-integrity verification, so the two can never diverge.
    public static func sha256Hex(ofCanonicalBytes bytes: Data) -> String {
        let digest = SHA256.hash(data: bytes)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The lowercase hex SHA-256 digest of `configuration`'s canonical bytes.
    public static func sha256Hex(of configuration: EngineConfiguration) -> String {
        sha256Hex(ofCanonicalBytes: CanonicalEncoding.canonicalBytes(of: configuration))
    }
}
