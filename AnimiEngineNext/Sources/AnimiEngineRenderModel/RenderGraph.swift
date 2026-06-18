/// Task-003 plan §7, D3-11 — the immutable, deterministic RenderGraph value.
///
/// §7 fixes the graph's structure (output canvas + reference colour profile, an ordered command list
/// drawn from the pinned `RenderCommandCategory` set, ending in the final BGRA8 output) and the
/// determinism contract (D3-11: value-identical inputs produce a value-identical graph and a stable
/// graph hash). Per the approved Stage-3 scope this models exactly those pinned invariants. The graph
/// *compiler* and the full graph *validator* (with all §7.4 reject conditions that depend on command
/// payloads) are §17 step 9 and are not implemented here.
///
/// Pinned invariants enforced at construction:
///   * command ordinals are dense and contiguous from `0` (ordering integrity, §7.1);
///   * there is **exactly one** `finalOutput`, and it is the **last** command (§7 completeness);
///   * there is **exactly one** `finalLinearToSRGB`, and it is **immediately before** `finalOutput`
///     (§7: "final linear-to-sRGB conversion" then "final BGRA8 output command") (item 9).
public struct RenderGraph: Hashable, Sendable {
    /// The configuration whose output canvas and colour contract this graph targets (§7).
    public let configuration: RenderConfiguration
    /// The ordered command list (§7.1 — order is semantic).
    public let commands: [RenderCommand]

    public init(configuration: RenderConfiguration, commands: [RenderCommand]) throws {
        guard !commands.isEmpty else {
            throw RenderModelError.unsupportedValue(field: "RenderGraph.commands", value: "empty")
        }
        // Ordinals must be dense and contiguous from 0, matching list position (§7.1 ordering).
        for (index, command) in commands.enumerated() {
            guard command.ordinal == index else {
                throw RenderModelError.valueOutOfRange(
                    field: "RenderGraph.commands.ordinal", value: Int64(command.ordinal),
                    lowerBound: Int64(index), upperBound: Int64(index))
            }
        }
        // Completion invariants (item 9): exactly one finalOutput, last; exactly one
        // finalLinearToSRGB, immediately before it.
        let outputCount = commands.filter { $0.category == .finalOutput }.count
        guard outputCount == 1 else {
            throw RenderModelError.unsupportedValue(
                field: "RenderGraph.finalOutputCount", value: String(outputCount))
        }
        guard commands.last?.category == .finalOutput else {
            throw RenderModelError.unsupportedValue(
                field: "RenderGraph.finalCommand",
                value: commands.last.map { $0.category.rawValue } ?? "none")
        }
        let srgbCount = commands.filter { $0.category == .finalLinearToSRGB }.count
        guard srgbCount == 1 else {
            throw RenderModelError.unsupportedValue(
                field: "RenderGraph.finalLinearToSRGBCount", value: String(srgbCount))
        }
        // commands.count >= 1 and last is finalOutput, so a preceding command exists iff count >= 2.
        guard commands.count >= 2, commands[commands.count - 2].category == .finalLinearToSRGB else {
            throw RenderModelError.unsupportedValue(
                field: "RenderGraph.finalLinearToSRGBPosition",
                value: "must immediately precede finalOutput")
        }
        self.configuration = configuration
        self.commands = commands
    }

    // MARK: - Canonical encoding / deterministic graph hash (D3-11)

    /// Canonical value of the graph: the **complete canonical configuration** (item 5) plus the
    /// ordered command list. Embedding the full configuration (which carries frame-rate
    /// numerator/denominator) ensures otherwise-identical 30-fps and 60-fps graphs hash differently.
    public func canonicalValue() throws -> RenderCanonicalEncoding.Value {
        try RenderCanonicalEncoding.object([
            ("commands", .array(try commands.map { try $0.canonicalValue() })),
            ("configuration", try configuration.canonicalValue())
        ])
    }

    /// The deterministic graph hash (D3-11): value-identical graphs produce identical hashes.
    public func graphHash() throws -> String {
        try RenderCanonicalEncoding.sha256Hex(of: canonicalValue(), domain: .renderGraph)
    }
}
