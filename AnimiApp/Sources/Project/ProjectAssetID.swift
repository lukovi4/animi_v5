import Foundation

/// Logical identity for a project media asset.
/// Decouples asset identity from storage path — two copies of the same file
/// in different projects get distinct IDs.
public struct ProjectAssetID: Codable, Hashable, Sendable {
    public let rawValue: UUID
    public init() { self.rawValue = UUID() }
    public init(rawValue: UUID) { self.rawValue = rawValue }
}
