import Foundation
import AnimiEngineCore

/// Stage 1 — one bounded, immutable canonical PCM render result for exactly one `CanonicalPCMRenderKey`.
///
/// A chunk is the **exact bounded unit** the cache stores: its `range` equals `key.range`, and EVERY source
/// it carries covers exactly that range (`source.buffer.chunkRange == key.range`). This strict rule keeps
/// Stage 1 honest — the cache stores whole bounded chunks, never partial/overlapping fragments. (Partial
/// segment rendering, if ever needed, is a future stage and would relax this with its own typed contract.)
///
/// An EMPTY `sources` array is *structurally* allowed (the chunk simply carries no audible contribution for
/// the range). The cache does NOT use emptiness to decide "semantic silence" — that decision is made above,
/// by whoever evaluates the `AudioPlan`; the cache only stores/returns what the renderer produced.
struct CanonicalPCMChunk: Sendable {
    let key: CanonicalPCMRenderKey
    let range: AudioSampleRange
    let sources: [PreviewMixSource]

    /// Fail-closed: every source must cover EXACTLY `key.range`. `range` is derived from the key (so the
    /// chunk's `range == key.range` always holds).
    init(key: CanonicalPCMRenderKey, sources: [PreviewMixSource]) throws {
        for source in sources {
            guard source.buffer.chunkRange == key.range else {
                throw AppRealtimeAudioIntegrationError.pcmRenderFailed(
                    reason: "chunk source range \(source.buffer.chunkRange) != key range \(key.range)")
            }
        }
        self.key = key
        self.range = key.range
        self.sources = sources
    }
}
