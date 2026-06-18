/// The full persisted project document: a manifest plus its payload tables (Task-002 plan, §11.1).
///
/// Runtime evaluation uses the manifest-derived index plus only selected payloads; the document is
/// the on-disk form, decoded once through strict validation.
public struct CanonicalProjectDocument: Equatable, Sendable {
    public let manifest: CanonicalProjectManifest
    public let scenePayloads: [ResolvedScenePayload]
    public let overlayPayloads: [ResolvedOverlayPayload]

    public init(
        manifest: CanonicalProjectManifest,
        scenePayloads: [ResolvedScenePayload],
        overlayPayloads: [ResolvedOverlayPayload]
    ) {
        self.manifest = manifest
        self.scenePayloads = scenePayloads
        self.overlayPayloads = overlayPayloads
    }
}
