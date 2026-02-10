import Foundation

// MARK: - Compiled Scene Payload

/// JSON payload wrapper for compiled.tve file.
/// Contains the compiled scene data plus metadata for diagnostics.
public struct CompiledScenePayload: Codable {
    /// The compiled scene (runtime-ready)
    public let compiled: CompiledScene

    /// Template identifier (from scene.sceneId or folder name)
    public let templateId: String?

    /// Template revision (starts at 1, increment on rebuild)
    public let templateRevision: Int

    /// Engine version string for diagnostics (e.g., "0.1.0")
    public let engineVersion: String

    public init(
        compiled: CompiledScene,
        templateId: String?,
        templateRevision: Int,
        engineVersion: String
    ) {
        self.compiled = compiled
        self.templateId = templateId
        self.templateRevision = templateRevision
        self.engineVersion = engineVersion
    }
}
