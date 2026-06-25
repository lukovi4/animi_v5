/// The canonical audio value model + manifest (Slice 001, plan §3.2/§3.4; ADR-012 §1).
///
/// These are pure, value-semantic, `Sendable` types with **no `Float`/`Double`** and no
/// AVFoundation/TVECore/app coupling: typed IDs, asset reference, roles, gain,
/// `destination`/`sourceTrim`, policy, entries, and the manifest.
///
/// **Stage C** wires the populated codec: a populated ``AudioManifest`` encodes and round-trips
/// byte-stable through `CanonicalProjectEncoding`. The populated initializer is `public` (plan §3.4).
///
/// **Stage D** semantic validation (uniqueness, dangling refs, role↔`videoLayer` agreement,
/// scene/layer payload resolution, `sourceTrim` containment, duplicate video-audio clips) is NOT yet
/// implemented — Stage C is strict codec shape only.

// MARK: - Roles, policy, asset reference

/// The role of an audio source. Closed `String`-raw enum so the codec maps tags 1:1 and an unknown
/// tag is a typed decoding failure (Stage C).
public enum AudioSourceRole: String, Hashable, Sendable, CaseIterable {
    case videoLayer, music, voiceover, soundEffect
}

/// The clip playback policy. `.once` is the ONLY case in v1 — no loop/loopToFit/wrap is representable
/// (ADR-012 §1: "no wrap, repetition, implicit extension, or loopToFit").
public enum AudioPlaybackPolicy: String, Hashable, Sendable {
    case once
}

/// What an audio source points at. A closed enum, role-tagged in JSON (`kind`) at codec time.
public enum AudioAssetReference: Hashable, Sendable {
    /// A video layer's own audio track (reuses the existing ``MediaReference``).
    case videoLayerMedia(MediaReference)
    /// A global music/voiceover/SFX asset (opaque provenance id; no URL/path).
    case globalAudio(GlobalAudioAssetID)
}

// MARK: - Scene-layer reference

/// A scene-local layer reference. `LayerID` is scene-local, so the scene instance must accompany it.
public struct SceneLayerReference: Hashable, Sendable {
    public let sceneID: SceneInstanceID
    public let layerID: LayerID
    public init(sceneID: SceneInstanceID, layerID: LayerID) {
        self.sceneID = sceneID
        self.layerID = layerID
    }
}

// MARK: - Entries

public struct AudioSourceEntry: Hashable, Sendable {
    public let id: AudioSourceID
    public let asset: AudioAssetReference
    public init(id: AudioSourceID, asset: AudioAssetReference) {
        self.id = id
        self.asset = asset
    }
}

public struct AudioTrackEntry: Hashable, Sendable {
    public let id: AudioTrackID
    public let role: AudioSourceRole
    public init(id: AudioTrackID, role: AudioSourceRole) {
        self.id = id
        self.role = role
    }
}

/// `Equatable` (not `Hashable`): `destination`/`sourceTrim` are `ProjectTimeRange`/
/// `RationalSourceRange`, which are `Equatable`/`Sendable` but not `Hashable`. The clip never needs
/// to be a dictionary key, so this matches the existing time-type conformances exactly.
public struct AudioClipEntry: Equatable, Sendable {
    public let id: AudioClipID
    public let trackID: AudioTrackID
    public let sourceID: AudioSourceID
    /// Non-nil exactly when the clip's role is `.videoLayer` (enforced by Stage-D validation).
    public let videoLayer: SceneLayerReference?
    public let destination: ProjectTimeRange
    public let sourceTrim: RationalSourceRange
    public let gain: AudioGain
    public let isMuted: Bool
    /// `== .once` in v1 (re-asserted by validation).
    public let playbackPolicy: AudioPlaybackPolicy

    public init(
        id: AudioClipID,
        trackID: AudioTrackID,
        sourceID: AudioSourceID,
        videoLayer: SceneLayerReference?,
        destination: ProjectTimeRange,
        sourceTrim: RationalSourceRange,
        gain: AudioGain,
        isMuted: Bool,
        playbackPolicy: AudioPlaybackPolicy
    ) {
        self.id = id
        self.trackID = trackID
        self.sourceID = sourceID
        self.videoLayer = videoLayer
        self.destination = destination
        self.sourceTrim = sourceTrim
        self.gain = gain
        self.isMuted = isMuted
        self.playbackPolicy = playbackPolicy
    }
}

// MARK: - Manifest

/// The canonical audio manifest: three tables. A populated manifest encodes and round-trips
/// byte-stable through the Stage-C codec.
///
/// The populated initializer is `public` (plan §3.4). `Equatable`/`Sendable` are free; the manifest
/// mirrors ``CanonicalProjectManifest`` (no `Hashable` requirement).
public struct AudioManifest: Equatable, Sendable {
    public let sources: [AudioSourceEntry]
    public let tracks: [AudioTrackEntry]
    public let clips: [AudioClipEntry]

    public init(sources: [AudioSourceEntry], tracks: [AudioTrackEntry], clips: [AudioClipEntry]) {
        self.sources = sources
        self.tracks = tracks
        self.clips = clips
    }

    /// The canonical empty audio manifest. The uplift target for v1/v2 documents and the default
    /// for the manifest initializer.
    public static let empty = AudioManifest(sources: [], tracks: [], clips: [])

    /// `true` when all three tables are empty.
    public var isEmpty: Bool { sources.isEmpty && tracks.isEmpty && clips.isEmpty }
}
