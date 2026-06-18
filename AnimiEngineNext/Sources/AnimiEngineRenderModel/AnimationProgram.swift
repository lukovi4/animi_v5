import AnimiEngineCore

/// Task-003 plan §4.1, §6, §7.2 — the render-model identity and pinned invariants for a compiled
/// animation program.
///
/// Per the approved Stage-3 scope this models only what the plan fixes now: a program's stable
/// identity and its authored duration invariant (strictly positive ticks, matching the Task-002
/// `AnimationReference` rule), plus the request category the graph compiler will issue against it.
/// The compiled track/keyframe **field schema** — sampled by the animation sampler in §17 step 8 — is
/// intentionally not defined here; it is co-designed with its consumer.
///
/// The supported request set is exactly Task-002's ``AnimiEngineCore/AnimationRequest``
/// (`.sample` / `.looped` / `.holdLast` / `.inactive`, §7.2); the render model re-exports it rather
/// than inventing a parallel enum.
public typealias RenderAnimationRequest = AnimationRequest

/// A stable identity for an animation program within the render model.
public struct AnimationProgramID: Hashable, Sendable, Comparable {
    public let rawValue: String
    public init(_ rawValue: String) throws {
        guard !rawValue.isEmpty else {
            throw RenderModelError.emptyIdentifier(field: "AnimationProgramID")
        }
        self.rawValue = rawValue
    }
    public static func < (lhs: AnimationProgramID, rhs: AnimationProgramID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A compiled animation program's identity and authored time domain. Sampling is deterministic and
/// has no wall clock (D3-06); the actual track data and sampler are added in step 8 with the sampler
/// as their consumer.
///
/// The authored duration is a Task-002 ``AnimiEngineCore/TickDuration`` (item 4). `TickDuration`
/// permits zero, but an animation program with no extent is invalid, so construction additionally
/// requires `> 0`.
public struct AnimationProgram: Hashable, Sendable {
    public let id: AnimationProgramID
    /// Authored duration as a Task-002 tick duration; strictly positive.
    public let authoredDuration: TickDuration

    public init(id: AnimationProgramID, authoredDuration: TickDuration) throws {
        guard authoredDuration.ticks > 0 else {
            throw RenderModelError.valueOutOfRange(
                field: "AnimationProgram.authoredDuration",
                value: authoredDuration.ticks, lowerBound: 1, upperBound: Int64.max)
        }
        self.id = id
        self.authoredDuration = authoredDuration
    }

    // MARK: - Canonical encoding / stable program hash (item 4, D3-11)

    /// Canonical value: program id and authored duration ticks.
    public func canonicalValue() throws -> RenderCanonicalEncoding.Value {
        try RenderCanonicalEncoding.object([
            ("authoredDurationTicks", .int(authoredDuration.ticks)),
            ("id", .string(id.rawValue))
        ])
    }

    /// Domain-scoped SHA-256 over the canonical bytes (item 4). Stable for value-identical programs.
    public func programHash() throws -> String {
        try RenderCanonicalEncoding.sha256Hex(of: canonicalValue(), domain: .animationProgram)
    }
}
