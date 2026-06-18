/// The lightweight project manifest (Task-002 plan, §6.1).
///
/// The manifest plus a selected set of payloads is sufficient to evaluate any single frame; the
/// full payload tables are never required by the evaluator.
public struct CanonicalProjectManifest: Equatable, Sendable {
    /// The only schema version Task 002 supports (corrective plan C-5).
    public static let supportedSchemaVersion = 1

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

    /// The sum of all scene nominal durations (Task-002 plan, §7.4). Transition durations never
    /// change this value.
    public func projectDuration() throws -> TickDuration {
        var total = TickDuration.zero
        for scene in scenes {
            total = try total.adding(scene.nominalDuration)
        }
        return total
    }
}
