import Foundation

/// Versioned, typed engine configuration (decision **D-109**).
///
/// Every value here is a **placeholder** — Task 001 does not declare any value "optimal."
/// The type exists so that:
///   * configuration is *versioned* (``schemaVersion``),
///   * configuration can be hashed to a stable, reproducible digest (see `ConfigurationHash`),
///   * unrecorded configuration changes are impossible (strict decode rejects unknown fields).
///
/// The type is `Codable` with **explicit `CodingKeys` on every keyed object**, so that
/// `ConfigurationDecoder` can validate each nested container against its known key set.
///
/// No decoder/renderer/proxy/cache/audio/export/UI behaviour is implemented or implied by
/// these fields — they are inert configuration placeholders only.
public struct EngineConfiguration: Codable, Equatable, Sendable {
    /// Schema version of this configuration document. The decoder rejects any value other
    /// than ``supportedSchemaVersion``.
    public var schemaVersion: Int

    /// Project (authoring) frame rate, in frames per second.
    public var projectFrameRate: Int

    /// Preview frame-rate ladder placeholder.
    public var preview: PreviewConfiguration

    /// Decoder backend selection + pool limits placeholder.
    public var decoder: DecoderConfiguration

    /// Proxy profile placeholders.
    public var proxy: ProxyConfiguration

    /// Cache profile placeholders.
    public var cache: CacheConfiguration

    /// Render-quality profile placeholders.
    public var renderQuality: RenderQualityConfiguration

    /// Memory-limit placeholders.
    public var memory: MemoryConfiguration

    /// Export profile placeholders.
    public var export: ExportConfiguration

    /// Diagnostics sampling + output placeholders.
    public var diagnostics: DiagnosticsConfiguration

    /// The single schema version this build understands.
    public static let supportedSchemaVersion = 1

    public init(
        schemaVersion: Int = EngineConfiguration.supportedSchemaVersion,
        projectFrameRate: Int,
        preview: PreviewConfiguration,
        decoder: DecoderConfiguration,
        proxy: ProxyConfiguration,
        cache: CacheConfiguration,
        renderQuality: RenderQualityConfiguration,
        memory: MemoryConfiguration,
        export: ExportConfiguration,
        diagnostics: DiagnosticsConfiguration
    ) {
        self.schemaVersion = schemaVersion
        self.projectFrameRate = projectFrameRate
        self.preview = preview
        self.decoder = decoder
        self.proxy = proxy
        self.cache = cache
        self.renderQuality = renderQuality
        self.memory = memory
        self.export = export
        self.diagnostics = diagnostics
    }

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case projectFrameRate
        case preview
        case decoder
        case proxy
        case cache
        case renderQuality
        case memory
        case export
        case diagnostics
    }
}

// MARK: - Nested placeholder objects

/// Preview frame-rate ladder placeholder.
public struct PreviewConfiguration: Codable, Equatable, Sendable {
    /// Candidate preview frame rates, highest preference first. Placeholder values.
    public var frameRateLadder: [Int]

    public init(frameRateLadder: [Int]) {
        self.frameRateLadder = frameRateLadder
    }

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case frameRateLadder
    }
}

/// Decoder backend + pool-limit placeholder.
public struct DecoderConfiguration: Codable, Equatable, Sendable {
    /// Opaque backend identifier placeholder (e.g. `"videoToolbox"`). Not interpreted in Task 001.
    public var backend: String
    /// Maximum number of pooled decoder sessions. Placeholder.
    public var poolLimit: Int

    public init(backend: String, poolLimit: Int) {
        self.backend = backend
        self.poolLimit = poolLimit
    }

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case backend
        case poolLimit
    }
}

/// Proxy profile placeholder.
public struct ProxyConfiguration: Codable, Equatable, Sendable {
    /// Named proxy profiles. Placeholder values.
    public var profiles: [ProxyProfile]

    public init(profiles: [ProxyProfile]) {
        self.profiles = profiles
    }

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case profiles
    }
}

/// A single proxy profile placeholder.
public struct ProxyProfile: Codable, Equatable, Sendable {
    public var name: String
    public var maxDimension: Int

    public init(name: String, maxDimension: Int) {
        self.name = name
        self.maxDimension = maxDimension
    }

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case name
        case maxDimension
    }
}

/// Cache profile placeholder.
public struct CacheConfiguration: Codable, Equatable, Sendable {
    /// Frame-cache budget in mebibytes. Placeholder.
    public var frameCacheBudgetMiB: Int
    /// On-disk proxy-cache budget in mebibytes. Placeholder.
    public var diskProxyBudgetMiB: Int

    public init(frameCacheBudgetMiB: Int, diskProxyBudgetMiB: Int) {
        self.frameCacheBudgetMiB = frameCacheBudgetMiB
        self.diskProxyBudgetMiB = diskProxyBudgetMiB
    }

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case frameCacheBudgetMiB
        case diskProxyBudgetMiB
    }
}

/// Render-quality profile placeholder.
public struct RenderQualityConfiguration: Codable, Equatable, Sendable {
    /// Named render-quality profiles. Placeholder values.
    public var profiles: [RenderQualityProfile]

    public init(profiles: [RenderQualityProfile]) {
        self.profiles = profiles
    }

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case profiles
    }
}

/// A single render-quality profile placeholder.
public struct RenderQualityProfile: Codable, Equatable, Sendable {
    public var name: String
    /// Render scale factor in percent (1...100). Placeholder.
    public var scalePercent: Int

    public init(name: String, scalePercent: Int) {
        self.name = name
        self.scalePercent = scalePercent
    }

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case name
        case scalePercent
    }
}

/// Memory-limit placeholder.
public struct MemoryConfiguration: Codable, Equatable, Sendable {
    /// Soft memory budget in mebibytes. Placeholder.
    public var softLimitMiB: Int
    /// Hard memory budget in mebibytes. Placeholder.
    public var hardLimitMiB: Int

    public init(softLimitMiB: Int, hardLimitMiB: Int) {
        self.softLimitMiB = softLimitMiB
        self.hardLimitMiB = hardLimitMiB
    }

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case softLimitMiB
        case hardLimitMiB
    }
}

/// Export profile placeholder.
public struct ExportConfiguration: Codable, Equatable, Sendable {
    /// Named export profiles. Placeholder values.
    public var profiles: [ExportProfile]

    public init(profiles: [ExportProfile]) {
        self.profiles = profiles
    }

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case profiles
    }
}

/// A single export profile placeholder.
public struct ExportProfile: Codable, Equatable, Sendable {
    public var name: String
    public var frameRate: Int
    /// Average bitrate in bits per second. Placeholder.
    public var bitrate: Int

    public init(name: String, frameRate: Int, bitrate: Int) {
        self.name = name
        self.frameRate = frameRate
        self.bitrate = bitrate
    }

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case name
        case frameRate
        case bitrate
    }
}

/// Diagnostics sampling + output placeholder.
public struct DiagnosticsConfiguration: Codable, Equatable, Sendable {
    /// Event sampling rate in percent (0...100). Placeholder.
    public var samplingPercent: Int
    /// Opaque output sink identifier placeholder (e.g. `"ndjson"`). Not interpreted in Task 001.
    public var output: String

    public init(samplingPercent: Int, output: String) {
        self.samplingPercent = samplingPercent
        self.output = output
    }

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case samplingPercent
        case output
    }
}
