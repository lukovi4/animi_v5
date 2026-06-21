/// The lightweight project manifest (Task-002 plan, §6.1).
///
/// The manifest plus a selected set of payloads is sufficient to evaluate any single frame; the
/// full payload tables are never required by the evaluator.
public struct CanonicalProjectManifest: Equatable, Sendable {
    /// The schema version the CANONICAL ENCODER writes (CP7.5: bumped 1→2 to carry per-scene
    /// `timelineSpan`). New documents are always v2.
    public static let supportedSchemaVersion = 2
    /// Schema versions the DECODER accepts. v1 documents are uplifted on decode
    /// (`timelineSpan = nominalDuration`); v2 documents carry an explicit `timelineSpan`.
    public static let acceptedSchemaVersions: Set<Int> = [1, 2]

    public let schemaVersion: Int
    public let output: OutputContext
    public let scenes: [SceneManifestEntry]
    /// One transition per scene boundary; for `n` scenes there are exactly `n - 1` boundaries.
    public let boundaryTransitions: [SceneTransition]
    public let overlays: [OverlayManifestEntry]

    public init(
        schemaVersion: Int,
        output: OutputContext,
        scenes: [SceneManifestEntry],
        boundaryTransitions: [SceneTransition],
        overlays: [OverlayManifestEntry]
    ) {
        self.schemaVersion = schemaVersion
        self.output = output
        self.scenes = scenes
        self.boundaryTransitions = boundaryTransitions
        self.overlays = overlays
    }

    /// The sum of all scene TIMELINE SPANS (CP7.5). For an unstretched project `timelineSpan ==
    /// nominalDuration` for every scene, so this equals the original "sum of nominal durations".
    /// For a stretched scene the project extends across its full span. Transition durations never
    /// change this value.
    public func projectDuration() throws -> TickDuration {
        var total = TickDuration.zero
        for scene in scenes {
            total = try total.adding(scene.timelineSpan)
        }
        return total
    }
}
