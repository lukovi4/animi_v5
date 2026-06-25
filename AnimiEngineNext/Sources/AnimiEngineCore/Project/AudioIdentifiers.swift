/// Typed audio identifiers (Slice 001, plan §3.1; ADR-012 §1).
///
/// Each is a thin, value-typed wrapper over ``StructuralID`` — non-empty at construction (the
/// throwing init inherits `ProjectValidationError.emptyIdentifier`), with free `Hashable`/
/// `Comparable` for deterministic encoder ordering. They are distinct types so an audio source id
/// can never be confused with a track or clip id at a call site. This is the exact pattern of
/// `SceneInstanceID`/`LayerID`/… in `References.swift`.

public struct AudioSourceID: Hashable, Comparable, Sendable {
    public let id: StructuralID
    public init(_ raw: String) throws { id = try StructuralID(raw) }
    init(_ id: StructuralID) { self.id = id }
    public var raw: String { id.raw }
    public static func < (lhs: AudioSourceID, rhs: AudioSourceID) -> Bool { lhs.id < rhs.id }
}

public struct AudioTrackID: Hashable, Comparable, Sendable {
    public let id: StructuralID
    public init(_ raw: String) throws { id = try StructuralID(raw) }
    init(_ id: StructuralID) { self.id = id }
    public var raw: String { id.raw }
    public static func < (lhs: AudioTrackID, rhs: AudioTrackID) -> Bool { lhs.id < rhs.id }
}

public struct AudioClipID: Hashable, Comparable, Sendable {
    public let id: StructuralID
    public init(_ raw: String) throws { id = try StructuralID(raw) }
    init(_ id: StructuralID) { self.id = id }
    public var raw: String { id.raw }
    public static func < (lhs: AudioClipID, rhs: AudioClipID) -> Bool { lhs.id < rhs.id }
}

/// Opaque provenance id for global music / voiceover / SFX (no URL/path/AVAsset — resolution is a
/// later-slice concern).
public struct GlobalAudioAssetID: Hashable, Comparable, Sendable {
    public let id: StructuralID
    public init(_ raw: String) throws { id = try StructuralID(raw) }
    init(_ id: StructuralID) { self.id = id }
    public var raw: String { id.raw }
    public static func < (lhs: GlobalAudioAssetID, rhs: GlobalAudioAssetID) -> Bool { lhs.id < rhs.id }
}
