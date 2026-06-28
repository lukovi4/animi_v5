import Foundation
import AnimiEngineCore

/// Slice-005 Stage A — resolves the canonical `[ResolvedAudioSourceDescriptor]` for the sources a
/// manifest references (plan §3.1b). Each referenced `AudioSourceID` must resolve to **exactly one**
/// descriptor; zero or multiple is a typed failure (matching the canonical evaluator's
/// one-descriptor-per-source contract). Pure orchestration — the actual asset probing is behind an
/// injected protocol so unit tests use a fake (no `AVAssetReader`, no device).
///
/// Stage A scope: produce the descriptor list value only. No window build, no decode beyond probing.
enum AppAudioSourceDescriptorResolver {

    /// The integer/rational facts a probe yields for one source. Pure value; no `AVAsset`.
    struct ProbeResult: Equatable {
        let sampleRate: Int64
        let channelCount: Int
        /// Source duration as exact rational seconds (numerator/denominator).
        let durationNumerator: Int64
        let durationDenominator: Int64
        /// Stable opaque stream provenance string (non-empty).
        let streamIdentityRaw: String

        init(
            sampleRate: Int64,
            channelCount: Int,
            durationNumerator: Int64,
            durationDenominator: Int64,
            streamIdentityRaw: String
        ) {
            self.sampleRate = sampleRate
            self.channelCount = channelCount
            self.durationNumerator = durationNumerator
            self.durationDenominator = durationDenominator
            self.streamIdentityRaw = streamIdentityRaw
        }
    }

    /// The injected probe contract. A real implementation lives in an app-side file and may use
    /// AVFoundation; tests inject a fake. The probe returns **zero or more** results per source — the
    /// resolver enforces "exactly one".
    protocol Probe {
        /// All descriptor candidates the probe can resolve for a source. Empty = unresolvable;
        /// more than one = ambiguous. The resolver fails closed in both cases.
        func probe(sourceID: AudioSourceID) throws -> [ProbeResult]
    }

    /// Resolve exactly one `ResolvedAudioSourceDescriptor` per referenced source.
    ///
    /// - Parameters:
    ///   - manifest: the populated audio manifest whose clips name the referenced sources.
    ///   - probe: injected source probe.
    /// - Returns: descriptors ordered deterministically by `sourceID`.
    static func resolve(
        manifest: AudioManifest,
        probe: Probe
    ) throws -> [ResolvedAudioSourceDescriptor] {
        // The referenced sources are exactly those named by clips (a declared-but-unused source needs no
        // descriptor). Deterministic, de-duplicated order.
        let referenced = orderedReferencedSources(in: manifest)

        var descriptors: [ResolvedAudioSourceDescriptor] = []
        for sourceID in referenced {
            let candidates = try probe.probe(sourceID: sourceID)
            guard !candidates.isEmpty else {
                throw AppRealtimeAudioIntegrationError.missingSourceDescriptor(sourceRaw: sourceID.raw)
            }
            guard candidates.count == 1, let result = candidates.first else {
                throw AppRealtimeAudioIntegrationError.duplicateSourceDescriptor(sourceRaw: sourceID.raw)
            }
            descriptors.append(try makeDescriptor(sourceID: sourceID, result: result))
        }
        return descriptors
    }

    // MARK: - Helpers

    private static func orderedReferencedSources(in manifest: AudioManifest) -> [AudioSourceID] {
        var seen: Set<AudioSourceID> = []
        var ordered: [AudioSourceID] = []
        for clip in manifest.clips where seen.insert(clip.sourceID).inserted {
            ordered.append(clip.sourceID)
        }
        return ordered.sorted()
    }

    private static func makeDescriptor(
        sourceID: AudioSourceID, result: ProbeResult
    ) throws -> ResolvedAudioSourceDescriptor {
        guard result.sampleRate > 0 else {
            throw AppRealtimeAudioIntegrationError.invalidOutputSampleRate(raw: Double(result.sampleRate))
        }
        let layout = try channelLayout(count: result.channelCount)
        guard let streamIdentity = try? AudioStreamIdentity(result.streamIdentityRaw) else {
            throw AppRealtimeAudioIntegrationError.identifierConstructionFailed(
                detail: "streamIdentity:\(sourceID.raw)")
        }
        guard let duration = try? RationalSourceTime(
            numerator: result.durationNumerator, denominator: result.durationDenominator) else {
            throw AppRealtimeAudioIntegrationError.identifierConstructionFailed(
                detail: "duration:\(sourceID.raw)")
        }
        return ResolvedAudioSourceDescriptor(
            sourceID: sourceID,
            streamIdentity: streamIdentity,
            sourceDuration: duration,
            sampleRate: result.sampleRate,
            channelLayout: layout)
    }

    /// Map a probed channel count to the canonical descriptor (mono/stereo/validated discrete).
    static func channelLayout(count: Int) throws -> AudioChannelLayoutDescriptor {
        switch count {
        case 1: return .mono
        case 2: return .stereo
        default:
            guard count > 0, let layout = try? AudioChannelLayoutDescriptor.discrete(count: count) else {
                throw AppRealtimeAudioIntegrationError.invalidChannelCount(count)
            }
            return layout
        }
    }
}
