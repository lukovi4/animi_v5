import Foundation
import AnimiEngineCore

/// Stage 1 — the abstract canonical PCM render boundary.
///
/// A `CanonicalPCMRenderer` turns one `CanonicalAudioRenderRequest` into one bounded `CanonicalPCMChunk`.
/// Stage 1 ships NO real implementation: there is no media decode here and no live media pull — the renderer
/// is the seam a future background/prewarmed PCM renderer (or a deterministic test fake) plugs into. The
/// cache (`CanonicalPCMRenderCache`) depends only on this protocol, so it stays decode-free.
protocol CanonicalPCMRenderer: Sendable {
    /// Render the bounded chunk for `request`. Throwing is the fail-closed contract — a thrown error must
    /// NEVER be cached as success.
    func render(_ request: CanonicalAudioRenderRequest) async throws -> CanonicalPCMChunk
}
