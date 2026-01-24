import Foundation

/// Protocol for mask asset catalog lookup
/// Used by SceneValidator to verify maskRef references
public protocol MaskCatalog: Sendable {
    /// Checks if the catalog contains a mask with the given reference
    /// - Parameter maskRef: The mask reference to look up
    /// - Returns: true if the mask exists in the catalog
    func contains(maskRef: String) -> Bool
}
