import Foundation

/// Strict, recursive decoder for ``EngineConfiguration`` (Task-001 plan, "Configuration contract").
///
/// This deliberately **inverts** TVECore's *tolerant* Lottie decoder: decoding **fails** on
///   * an unknown field at **any** nesting depth — `ConfigurationError.unknownField(path:)`
///     carrying the full dotted key path,
///   * an out-of-range value — `ConfigurationError.outOfRange(path:reason:)`,
///   * an unsupported `schemaVersion` — `ConfigurationError.unsupportedSchema`.
///
/// Strategy: walk the parsed JSON object graph against an explicit *schema tree* (the set of
/// known keys per object), so unknown keys are caught with their full path before any value
/// construction. After structural validation succeeds, `JSONDecoder` builds the typed value,
/// and range checks run on the result.
public struct ConfigurationDecoder {
    public init() {}

    /// Decode strict JSON bytes into an ``EngineConfiguration``.
    public func decode(_ data: Data) throws -> EngineConfiguration {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw ConfigurationError.outOfRange(path: "", reason: "invalid JSON: \(error)")
        }

        // 1. Structural validation against the schema tree (unknown-field rejection, any depth).
        try validate(node: root, against: EngineConfiguration.schemaNode, path: "")

        // 2. Schema-version gate (explicit, before building the typed value).
        if let object = root as? [String: Any],
           let version = object["schemaVersion"] as? Int,
           version != EngineConfiguration.supportedSchemaVersion {
            throw ConfigurationError.unsupportedSchema(
                found: version,
                supported: EngineConfiguration.supportedSchemaVersion
            )
        }

        // 3. Typed construction.
        let configuration: EngineConfiguration
        do {
            configuration = try JSONDecoder().decode(EngineConfiguration.self, from: data)
        } catch {
            throw ConfigurationError.outOfRange(path: "", reason: "type mismatch: \(error)")
        }

        // 4. Range validation on the typed value.
        try validateRanges(configuration)

        return configuration
    }

    // MARK: - Structural validation

    /// Recursively validates `node` against `schema`, rejecting unknown keys at any depth.
    private func validate(node: Any, against schema: SchemaNode, path: String) throws {
        switch schema {
        case .object(let knownKeys):
            guard let object = node as? [String: Any] else {
                // A non-object where an object is expected is a type problem; let JSONDecoder
                // produce the precise message during typed construction.
                return
            }
            for key in object.keys {
                guard let childSchema = knownKeys[key] else {
                    throw ConfigurationError.unknownField(path: appending(path, key))
                }
                try validate(node: object[key]!, against: childSchema, path: appending(path, key))
            }

        case .arrayOf(let elementSchema):
            guard let array = node as? [Any] else { return }
            for (index, element) in array.enumerated() {
                try validate(node: element, against: elementSchema, path: "\(path)[\(index)]")
            }

        case .scalar:
            return
        }
    }

    private func appending(_ path: String, _ key: String) -> String {
        path.isEmpty ? key : "\(path).\(key)"
    }

    // MARK: - Range validation

    private func validateRanges(_ c: EngineConfiguration) throws {
        try requirePositive(c.projectFrameRate, path: "projectFrameRate")

        for (i, fps) in c.preview.frameRateLadder.enumerated() {
            try requirePositive(fps, path: "preview.frameRateLadder[\(i)]")
        }

        try requirePositive(c.decoder.poolLimit, path: "decoder.poolLimit")

        for (i, p) in c.proxy.profiles.enumerated() {
            try requirePositive(p.maxDimension, path: "proxy.profiles[\(i)].maxDimension")
        }

        try requireNonNegative(c.cache.frameCacheBudgetMiB, path: "cache.frameCacheBudgetMiB")
        try requireNonNegative(c.cache.diskProxyBudgetMiB, path: "cache.diskProxyBudgetMiB")

        for (i, p) in c.renderQuality.profiles.enumerated() {
            try requireInRange(
                p.scalePercent, min: 1, max: 100,
                path: "renderQuality.profiles[\(i)].scalePercent"
            )
        }

        try requireNonNegative(c.memory.softLimitMiB, path: "memory.softLimitMiB")
        try requireNonNegative(c.memory.hardLimitMiB, path: "memory.hardLimitMiB")
        if c.memory.hardLimitMiB < c.memory.softLimitMiB {
            throw ConfigurationError.outOfRange(
                path: "memory.hardLimitMiB",
                reason: "hardLimitMiB (\(c.memory.hardLimitMiB)) must be ≥ softLimitMiB (\(c.memory.softLimitMiB))"
            )
        }

        for (i, p) in c.export.profiles.enumerated() {
            try requirePositive(p.frameRate, path: "export.profiles[\(i)].frameRate")
            try requirePositive(p.bitrate, path: "export.profiles[\(i)].bitrate")
        }

        try requireInRange(
            c.diagnostics.samplingPercent, min: 0, max: 100,
            path: "diagnostics.samplingPercent"
        )
    }

    private func requirePositive(_ value: Int, path: String) throws {
        if value <= 0 {
            throw ConfigurationError.outOfRange(path: path, reason: "must be > 0, got \(value)")
        }
    }

    private func requireNonNegative(_ value: Int, path: String) throws {
        if value < 0 {
            throw ConfigurationError.outOfRange(path: path, reason: "must be ≥ 0, got \(value)")
        }
    }

    private func requireInRange(_ value: Int, min: Int, max: Int, path: String) throws {
        if value < min || value > max {
            throw ConfigurationError.outOfRange(
                path: path,
                reason: "must be in \(min)...\(max), got \(value)"
            )
        }
    }
}

// MARK: - Schema tree

/// A minimal description of the known shape of the configuration, used only for unknown-field
/// rejection during structural validation. It does NOT describe value types — typed construction
/// is delegated to `JSONDecoder`.
indirect enum SchemaNode {
    case object([String: SchemaNode])
    case arrayOf(SchemaNode)
    case scalar
}

extension EngineConfiguration {
    /// The schema tree mirroring the `CodingKeys` of every nested object.
    static let schemaNode: SchemaNode = .object([
        "schemaVersion": .scalar,
        "projectFrameRate": .scalar,
        "preview": .object([
            "frameRateLadder": .arrayOf(.scalar)
        ]),
        "decoder": .object([
            "backend": .scalar,
            "poolLimit": .scalar
        ]),
        "proxy": .object([
            "profiles": .arrayOf(.object([
                "name": .scalar,
                "maxDimension": .scalar
            ]))
        ]),
        "cache": .object([
            "frameCacheBudgetMiB": .scalar,
            "diskProxyBudgetMiB": .scalar
        ]),
        "renderQuality": .object([
            "profiles": .arrayOf(.object([
                "name": .scalar,
                "scalePercent": .scalar
            ]))
        ]),
        "memory": .object([
            "softLimitMiB": .scalar,
            "hardLimitMiB": .scalar
        ]),
        "export": .object([
            "profiles": .arrayOf(.object([
                "name": .scalar,
                "frameRate": .scalar,
                "bitrate": .scalar
            ]))
        ]),
        "diagnostics": .object([
            "samplingPercent": .scalar,
            "output": .scalar
        ])
    ])
}
