import AnimiEngineCore

/// Task-003 plan §7, §8, D3-08, D3-11 — the immutable render configuration consumed by graph
/// compilation and Metal execution.
///
/// It pins the output grid, the reference colour contract, the intermediate compositing profile, and
/// the bounded frames-in-flight (§8: configured as `1` for Task-003 static rendering). It is a pure
/// value: no IO, no device handles, no caches.
///
/// `Equatable`/`Hashable` are implemented **directly on this type** over the Core values' public
/// fields (item 6); the imported `OutputContext` is not retroactively extended.
public struct RenderConfiguration: Sendable {
    /// The output canvas + frame rate grid (Task-002 `OutputContext`).
    public let output: OutputContext
    /// The pinned output colour/alpha contract (D3-08).
    public let colorContract: RenderColorContract
    /// The intermediate compositing profile (D3-08). `rgba16FloatLinear` is the correctness reference.
    public let intermediateProfile: IntermediateProfile
    /// Bounded frames in flight. Task-003 static rendering uses `1` (§8); must be strictly positive.
    public let framesInFlight: Int

    public init(
        output: OutputContext,
        colorContract: RenderColorContract = .task003,
        intermediateProfile: IntermediateProfile,
        framesInFlight: Int = 1
    ) throws {
        guard framesInFlight >= 1 else {
            throw RenderModelError.valueOutOfRange(
                field: "RenderConfiguration.framesInFlight",
                value: Int64(framesInFlight), lowerBound: 1, upperBound: Int64.max)
        }
        self.output = output
        self.colorContract = colorContract
        self.intermediateProfile = intermediateProfile
        self.framesInFlight = framesInFlight
    }

    // MARK: - Canonical encoding / configuration hash (item 5, D3-11)

    /// Canonical value: canvas, frame-rate numerator/denominator, the complete colour contract, the
    /// intermediate profile and framesInFlight (item 5). The frame rate is embedded as
    /// numerator+denominator so configurations differing only in fps (e.g. 30 vs 60) produce
    /// different canonical bytes and therefore different hashes.
    public func canonicalValue() throws -> RenderCanonicalEncoding.Value {
        try RenderCanonicalEncoding.object([
            ("canvasHeight", .int(output.canvas.height)),
            ("canvasWidth", .int(output.canvas.width)),
            ("colorContract", try RenderCanonicalEncoding.object([
                ("alphaStorage", .string(colorContract.alphaStorage.rawValue)),
                ("colorSpace", .string(colorContract.colorSpace.rawValue)),
                ("dynamicRange", .string(colorContract.dynamicRange.rawValue)),
                ("outputFormat", .string(colorContract.outputFormat.rawValue))
            ])),
            ("frameRateDenominator", .int(output.frameRate.denominator)),
            ("frameRateNumerator", .int(output.frameRate.numerator)),
            ("framesInFlight", .int(Int64(framesInFlight))),
            ("intermediateProfile", .string(intermediateProfile.rawValue))
        ])
    }

    /// Domain-scoped SHA-256 over the canonical bytes (item 5).
    public func configurationHash() throws -> String {
        try RenderCanonicalEncoding.sha256Hex(of: canonicalValue(), domain: .renderConfiguration)
    }
}

extension RenderConfiguration: Equatable {
    /// Equality over the Core values' public fields — no retroactive `OutputContext` conformance.
    public static func == (lhs: RenderConfiguration, rhs: RenderConfiguration) -> Bool {
        lhs.output.canvas.width == rhs.output.canvas.width &&
        lhs.output.canvas.height == rhs.output.canvas.height &&
        lhs.output.frameRate.numerator == rhs.output.frameRate.numerator &&
        lhs.output.frameRate.denominator == rhs.output.frameRate.denominator &&
        lhs.colorContract == rhs.colorContract &&
        lhs.intermediateProfile == rhs.intermediateProfile &&
        lhs.framesInFlight == rhs.framesInFlight
    }
}

extension RenderConfiguration: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(output.canvas.width)
        hasher.combine(output.canvas.height)
        hasher.combine(output.frameRate.numerator)
        hasher.combine(output.frameRate.denominator)
        hasher.combine(colorContract)
        hasher.combine(intermediateProfile)
        hasher.combine(framesInFlight)
    }
}
