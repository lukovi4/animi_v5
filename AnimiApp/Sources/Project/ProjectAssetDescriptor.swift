import Foundation

/// Registry entry describing a project asset's kind and storage location.
public struct ProjectAssetDescriptor: Codable, Equatable, Sendable {
    public var assetId: ProjectAssetID
    public var mediaKind: MediaKind
    /// Relative path within the project directory — internal detail, not identity.
    public var storagePath: String

    public init(assetId: ProjectAssetID, mediaKind: MediaKind, storagePath: String) {
        self.assetId = assetId
        self.mediaKind = mediaKind
        self.storagePath = storagePath
    }
}
