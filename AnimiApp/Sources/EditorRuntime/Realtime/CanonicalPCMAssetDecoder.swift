import Foundation
import AnimiEngineCore

/// Slice-005 Stage 3 — the bounded raw-PCM decode SEAM (protocol + value types ONLY).
///
/// This file declares the abstraction the background renderer (`BackgroundCanonicalPCMRenderer`) uses to
/// turn one bounded source sub-window into mono 48 kHz `Float32` samples. It contains NO concrete decoder,
/// NO AVFoundation, and NO test/fixture types — the real decoder lives in `AVFoundationPCMAssetDecoder.swift`
/// (the sole AV boundary), and fixture/spy decoders live in the test target only.
///
/// Contract: the decoder returns EXACTLY `frameCount` mono 48 kHz `Float32` samples for the requested
/// source window — **raw** samples (pre-gain, pre-mute, pre-mix, pre-output-stage). Gain/mute/mix/output are
/// the `PreviewAudioGraph`'s responsibility, never the decoder's.

/// One bounded decode request: a resolved source + the exact source-time window to decode.
struct CanonicalPCMAssetDecodeRequest: Sendable, Equatable {
    /// The resolved source location (URL only; the decoder owns any reader lifetime).
    let source: CanonicalResolvedAudioSource
    /// The raw source identifier (for typed diagnostics / errors); not used as decode input.
    let sourceIDRaw: String
    /// The exact rational source start (seconds) of the first requested frame. No `Double`, no µs truncation.
    let sourceStart: RationalSourceTime
    /// The exact number of mono 48 kHz frames to produce. Always `>= 1` for a non-empty bounded chunk.
    let frameCount: Int
}

/// The bounded raw-PCM decode boundary. `Sendable`; implementations must be safe to call off the main actor.
///
/// `decodeMono48kFloat32` MUST return exactly `request.frameCount` samples or throw a typed error — it must
/// never return a short/long/empty buffer for a non-empty request, and must never silently substitute
/// silence for audible content.
protocol CanonicalPCMAssetDecoder: Sendable {
    func decodeMono48kFloat32(_ request: CanonicalPCMAssetDecodeRequest) async throws -> [Float32]
}
