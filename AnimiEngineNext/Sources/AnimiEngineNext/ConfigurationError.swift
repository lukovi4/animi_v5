import Foundation

/// Typed errors raised while decoding/validating an ``EngineConfiguration``.
///
/// Mirrors the `enum + LocalizedError` pattern used by
/// `TVECore/Sources/TVECompilerCore/Loader/ScenePackageLoadError.swift`.
///
/// Unlike TVECore's *tolerant* Lottie decoder, the engine configuration decoder is
/// **strict**: unknown fields at any nesting depth, out-of-range values, and unsupported
/// schema versions are all hard failures (Task-001 plan, "Configuration contract").
public enum ConfigurationError: Error, Equatable, Sendable {
    /// An unknown key was present in a keyed container. `path` is the full dotted key path
    /// from the configuration root (e.g. `"preview.frameRateLadder"`).
    case unknownField(path: String)

    /// A value fell outside its permitted range. `path` is the full dotted key path and
    /// `reason` describes the violated constraint.
    case outOfRange(path: String, reason: String)

    /// The configuration declared a `schemaVersion` this build does not support.
    case unsupportedSchema(found: Int, supported: Int)
}

// MARK: - LocalizedError

extension ConfigurationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unknownField(let path):
            return "Unknown configuration field: \(path)"

        case .outOfRange(let path, let reason):
            return "Configuration value out of range at \(path): \(reason)"

        case .unsupportedSchema(let found, let supported):
            return "Unsupported configuration schemaVersion \(found); this build supports \(supported)"
        }
    }
}

// MARK: - CustomStringConvertible

extension ConfigurationError: CustomStringConvertible {
    public var description: String {
        errorDescription ?? "Unknown ConfigurationError"
    }
}
