import Foundation
import AnimiEngineCore

/// Stage 1 — the deterministic identity of one bounded canonical PCM render result.
///
/// This is the cache key for the future canonical PCM renderer/cache boundary
/// (`AudioPlan -> background/prewarmed PCM render cache -> CanonicalAudioRenderPipeline -> PreviewAudioGraph`).
/// It is composed of **value fields only** so that the same logical render always hashes/compares equal:
///   - `revision` + `epoch` — the ADR-005 identity tuple (a new edit/transport interpretation must miss);
///   - `planIdentity` — a caller-supplied deterministic digest of the evaluated `AudioPlan` (NOT a URL, NOT
///     an object pointer, NOT a timestamp). It must be non-empty.
///   - `range` — the exact bounded 48 kHz sample range this chunk covers.
///
/// Deliberately excluded from identity (would break determinism / correctness):
///   - `Date`/`UUID`/random — non-deterministic;
///   - file URLs — a renamed/moved file with the same plan must still hit;
///   - object identity (`ObjectIdentifier`) — two equal requests must share a key.
struct CanonicalPCMRenderKey: Hashable, Sendable {
    let revision: ProjectRevision
    let epoch: PlaybackEpoch
    let planIdentity: String
    let range: AudioSampleRange

    /// Fail-closed: a non-empty `planIdentity` is required. No clamping, no fabricated default.
    init(
        revision: ProjectRevision,
        epoch: PlaybackEpoch,
        planIdentity: String,
        range: AudioSampleRange
    ) throws {
        guard !planIdentity.isEmpty else {
            throw AppRealtimeAudioIntegrationError.invalidPCMRenderPlanIdentity
        }
        self.revision = revision
        self.epoch = epoch
        self.planIdentity = planIdentity
        self.range = range
    }
}
