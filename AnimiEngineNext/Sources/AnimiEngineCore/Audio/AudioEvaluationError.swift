/// Typed failures at the audio builder/evaluator boundary (Slice-002 Stage B; ADR-012 §1.0b, §3).
///
/// These are evaluation-boundary errors, distinct from `ProjectValidationError` (Slice-1 validation
/// already ran). Stage B only *defines* them; the exactly-one resolution that raises
/// `unresolvedAudioSource`/`ambiguousAudioSource`/`noAudioStream` belongs to the Stage-C builder.
public enum AudioEvaluationError: Error, Equatable, Sendable {
    /// No `ResolvedAudioSourceDescriptor` exists for a referenced source.
    case unresolvedAudioSource(sourceID: String)
    /// More than one candidate stream resolved for a source (§1.0b "zero or multiple → typed failure").
    case ambiguousAudioSource(sourceID: String)
    /// Zero candidate streams resolved for a required (clip-present) source.
    case noAudioStream(sourceID: String)
    /// A requested interval lies outside the audio window's `coverage`.
    case audioWindowCoverageViolation
    /// A video-layer clip names a scene absent from the audio window.
    case unknownAudioWindowScene(sceneID: String)
    /// A resolved binding disagrees with its clip's role (defence in depth; builder-side).
    case inconsistentResolvedBinding(clipID: String)
    /// An `AudioStreamIdentity` was constructed from an empty string.
    case invalidAudioStreamIdentity
    /// An `AudioChannelLayoutDescriptor.discrete(count:)` was constructed with `count <= 0`.
    case invalidAudioChannelLayout
    /// Exact audio time/inverse math could not fit an intermediate or final value (fail-closed; the
    /// evaluator never wraps, clamps, or truncates).
    case audioTimeMathOverflow
}
