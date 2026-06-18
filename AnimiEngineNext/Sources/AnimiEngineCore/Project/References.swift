/// Structural identifiers and opaque media/template/content references (Task-002 plan, §6).
///
/// Every ID is a thin, value-typed wrapper over a non-empty string. They are distinct types so a
/// scene id can never be confused with an overlay id at a call site. Emptiness is rejected at
/// construction.

/// A non-empty opaque string identifier shared by all structural ID wrappers.
public struct StructuralID: Hashable, Comparable, Sendable {
    public let raw: String

    public init(_ raw: String) throws {
        guard !raw.isEmpty else { throw ProjectValidationError.emptyIdentifier }
        self.raw = raw
    }

    init(unchecked raw: String) {
        self.raw = raw
    }

    public static func < (lhs: StructuralID, rhs: StructuralID) -> Bool {
        lhs.raw < rhs.raw
    }
}

public struct SceneInstanceID: Hashable, Comparable, Sendable {
    public let id: StructuralID
    public init(_ raw: String) throws { id = try StructuralID(raw) }
    init(_ id: StructuralID) { self.id = id }
    public var raw: String { id.raw }
    public static func < (lhs: SceneInstanceID, rhs: SceneInstanceID) -> Bool { lhs.id < rhs.id }
}

public struct ScenePayloadID: Hashable, Comparable, Sendable {
    public let id: StructuralID
    public init(_ raw: String) throws { id = try StructuralID(raw) }
    init(_ id: StructuralID) { self.id = id }
    public var raw: String { id.raw }
    public static func < (lhs: ScenePayloadID, rhs: ScenePayloadID) -> Bool { lhs.id < rhs.id }
}

public struct OverlayID: Hashable, Comparable, Sendable {
    public let id: StructuralID
    public init(_ raw: String) throws { id = try StructuralID(raw) }
    init(_ id: StructuralID) { self.id = id }
    public var raw: String { id.raw }
    public static func < (lhs: OverlayID, rhs: OverlayID) -> Bool { lhs.id < rhs.id }
}

public struct OverlayPayloadID: Hashable, Comparable, Sendable {
    public let id: StructuralID
    public init(_ raw: String) throws { id = try StructuralID(raw) }
    init(_ id: StructuralID) { self.id = id }
    public var raw: String { id.raw }
    public static func < (lhs: OverlayPayloadID, rhs: OverlayPayloadID) -> Bool { lhs.id < rhs.id }
}

public struct LayerID: Hashable, Comparable, Sendable {
    public let id: StructuralID
    public init(_ raw: String) throws { id = try StructuralID(raw) }
    init(_ id: StructuralID) { self.id = id }
    public var raw: String { id.raw }
    public static func < (lhs: LayerID, rhs: LayerID) -> Bool { lhs.id < rhs.id }
}

public struct TransitionEffectID: Hashable, Sendable {
    public let raw: String
    public init(_ raw: String) throws {
        guard !raw.isEmpty else { throw ProjectValidationError.emptyIdentifier }
        self.raw = raw
    }
    init(unchecked raw: String) { self.raw = raw }
}

/// Opaque reference to project media (a clip in the resolved project).
public struct MediaReference: Hashable, Sendable {
    public let raw: String
    public init(_ raw: String) throws {
        guard !raw.isEmpty else { throw ProjectValidationError.emptyIdentifier }
        self.raw = raw
    }
}

/// Opaque reference to a still image asset.
public struct ImageReference: Hashable, Sendable {
    public let raw: String
    public init(_ raw: String) throws {
        guard !raw.isEmpty else { throw ProjectValidationError.emptyIdentifier }
        self.raw = raw
    }
}

/// Opaque reference to a text-content payload.
public struct TextContentReference: Hashable, Sendable {
    public let raw: String
    public init(_ raw: String) throws {
        guard !raw.isEmpty else { throw ProjectValidationError.emptyIdentifier }
        self.raw = raw
    }
}

/// Opaque reference to a template (test fixtures resolve these; the core never loads them).
public struct TemplateReference: Hashable, Sendable {
    public let catalogID: String
    public let sceneID: String
    public init(catalogID: String, sceneID: String) throws {
        guard !catalogID.isEmpty, !sceneID.isEmpty else { throw ProjectValidationError.emptyIdentifier }
        self.catalogID = catalogID
        self.sceneID = sceneID
    }
}

/// Opaque reference to an easing curve (validated as non-empty; interpretation is deferred).
public struct EasingReference: Hashable, Sendable {
    public let raw: String
    public init(_ raw: String) throws {
        guard !raw.isEmpty else { throw ProjectValidationError.invalidEasing }
        self.raw = raw
    }
    init(unchecked raw: String) { self.raw = raw }
}
