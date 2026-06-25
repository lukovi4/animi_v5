/// The lightweight project manifest (Task-002 plan, §6.1).
///
/// The manifest plus a selected set of payloads is sufficient to evaluate any single frame; the
/// full payload tables are never required by the evaluator.
public struct CanonicalProjectManifest: Equatable, Sendable {
    /// The schema version the CANONICAL ENCODER writes (CP7.5: bumped 1→2 to carry per-scene
    /// `timelineSpan`; Slice 001: bumped 2→3 to carry the required `audio` field). New documents
    /// are always v3.
    public static let supportedSchemaVersion = 3
    /// Schema versions the DECODER accepts. v1 documents are uplifted on decode
    /// (`timelineSpan = nominalDuration`); v2 documents carry an explicit `timelineSpan`; v3
    /// documents carry an explicit `audio` object. v1/v2 documents uplift to `audio = .empty`
    /// and must NOT themselves carry an `"audio"` key (rejected as an unknown field).
    public static let acceptedSchemaVersions: Set<Int> = [1, 2, 3]

    public let schemaVersion: Int
    public let output: OutputContext
    public let scenes: [SceneManifestEntry]
    /// One transition per scene boundary; for `n` scenes there are exactly `n - 1` boundaries.
    public let boundaryTransitions: [SceneTransition]
    public let overlays: [OverlayManifestEntry]
    /// The canonical audio manifest (Slice 001, schema v3). The 6th stored field. The initializer
    /// default `= .empty` keeps every existing call site compiling; the on-disk v3 schema still
    /// REQUIRES an explicit `"audio"` object (the decoder enforces presence).
    public let audio: AudioManifest

    public init(
        schemaVersion: Int,
        output: OutputContext,
        scenes: [SceneManifestEntry],
        boundaryTransitions: [SceneTransition],
        overlays: [OverlayManifestEntry],
        audio: AudioManifest = .empty
    ) {
        self.schemaVersion = schemaVersion
        self.output = output
        self.scenes = scenes
        self.boundaryTransitions = boundaryTransitions
        self.overlays = overlays
        self.audio = audio
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
