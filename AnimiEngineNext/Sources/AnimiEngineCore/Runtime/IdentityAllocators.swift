/// Slice-003 Stage A — deterministic monotonic identity allocators (ADR-005 §1).
///
/// Numeric identities (`ProjectRevision`, `PlaybackEpoch`, and the three request-ID kinds) are minted
/// by **monotonic** allocators. Allocation is fully deterministic: each allocator starts at a fixed
/// seed and increments by one per mint. There is no `Date()`, `UUID()`, randomness, or wall clock, so
/// a test that mints in a fixed order always observes the same identities.
///
/// The allocators are `mutating` value types behind narrow protocols. Mutating-value semantics keep the
/// allocator's monotonic counter explicit and `Sendable`-friendly (the serialized scheduler owns the
/// single allocator instance); there is no shared mutable global counter.

// MARK: - Protocols

public protocol RevisionAllocator: Sendable {
    mutating func next() -> ProjectRevision
}

public protocol EpochAllocator: Sendable {
    mutating func next() -> PlaybackEpoch
}

public protocol RequestIDAllocator: Sendable {
    mutating func nextFrameRequest() -> FrameRequestID
    mutating func nextMediaRequest() -> MediaRequestID
    mutating func nextAudioRequest() -> AudioRequestID
}

// MARK: - Deterministic implementations

/// Deterministic monotonic `ProjectRevision` allocator. First mint is `raw: 0`, then `1`, `2`, …
public struct MonotonicRevisionAllocator: RevisionAllocator {
    private var counter: Int64
    public init(start: Int64 = 0) { self.counter = start }

    public mutating func next() -> ProjectRevision {
        let value = counter
        counter += 1
        return ProjectRevision(raw: value)
    }
}

/// Deterministic monotonic `PlaybackEpoch` allocator. First mint is `raw: 0`, then `1`, `2`, …
public struct MonotonicEpochAllocator: EpochAllocator {
    private var counter: Int64
    public init(start: Int64 = 0) { self.counter = start }

    public mutating func next() -> PlaybackEpoch {
        let value = counter
        counter += 1
        return PlaybackEpoch(raw: value)
    }
}

/// Deterministic monotonic request-ID allocator. The three kinds advance **independent** counters, so
/// frame, media, and audio request IDs are minted in their own monotonic sequences.
public struct MonotonicRequestIDAllocator: RequestIDAllocator {
    private var frameCounter: Int64
    private var mediaCounter: Int64
    private var audioCounter: Int64

    public init(frameStart: Int64 = 0, mediaStart: Int64 = 0, audioStart: Int64 = 0) {
        self.frameCounter = frameStart
        self.mediaCounter = mediaStart
        self.audioCounter = audioStart
    }

    public mutating func nextFrameRequest() -> FrameRequestID {
        let value = frameCounter
        frameCounter += 1
        return FrameRequestID(raw: value)
    }

    public mutating func nextMediaRequest() -> MediaRequestID {
        let value = mediaCounter
        mediaCounter += 1
        return MediaRequestID(raw: value)
    }

    public mutating func nextAudioRequest() -> AudioRequestID {
        let value = audioCounter
        audioCounter += 1
        return AudioRequestID(raw: value)
    }
}
