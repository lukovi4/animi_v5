/// Slice-003 Stage F — audio-buffer admission (ADR-005 §8).
///
/// A decoded PCM range is described ONLY by its identity — project revision, playback epoch, audio
/// request, audio source, and exact 48 kHz sample range. There are NO PCM bytes here and no AVFoundation:
/// this slice validates whether a decoded range may enter a preview source buffer, and flushes
/// not-yet-rendered old-epoch ranges after a discontinuity. The realtime audio path is a later slice.

/// The identity of one decoded audio range awaiting admission into a preview source buffer (ADR-005 §8).
/// Carries no samples — only the coordinates the scheduler validates.
public struct DecodedAudioRangeDescriptor: Sendable, Equatable, Hashable {
    public let revision: ProjectRevision
    public let epoch: PlaybackEpoch
    public let request: AudioRequestID
    public let source: AudioSourceID
    public let sampleRange: AudioSampleRange

    public init(
        revision: ProjectRevision,
        epoch: PlaybackEpoch,
        request: AudioRequestID,
        source: AudioSourceID,
        sampleRange: AudioSampleRange
    ) {
        self.revision = revision
        self.epoch = epoch
        self.request = request
        self.source = source
        self.sampleRange = sampleRange
    }
}

public enum AudioRangeAdmission {

    /// Validate a decoded range against the active snapshot before it enters a preview source buffer
    /// (ADR-005 §8). A range from a stale revision or a stale (superseded) epoch cannot be buffered.
    /// Pure; no PCM, no I/O, no device.
    public static func admit(
        _ descriptor: DecodedAudioRangeDescriptor,
        against snapshot: SchedulerSnapshot
    ) -> Result<Void, RejectionReason> {
        guard descriptor.revision == snapshot.revision else { return .failure(.staleRevision) }
        guard descriptor.epoch == snapshot.epoch else { return .failure(.staleEpoch) }
        return .success(())
    }

    /// After a discontinuity (seek, interruption, route change, project edit) the active epoch advances.
    /// Every not-yet-rendered range from a now-old epoch must be flushed from the buffer (ADR-005 §8,
    /// §4.3). Returns the surviving descriptors (those of the current epoch), preserving input order.
    /// Already-submitted (rendered) audio cannot be recalled and is not represented here.
    public static func flushingOldEpoch(
        _ pending: [DecodedAudioRangeDescriptor],
        currentEpoch: PlaybackEpoch
    ) -> [DecodedAudioRangeDescriptor] {
        pending.filter { $0.epoch == currentEpoch }
    }
}
