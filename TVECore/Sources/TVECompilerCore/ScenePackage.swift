import Foundation
import TVECore

/// ScenePackage represents a loaded scene with all its resources
public struct ScenePackage: Equatable, Sendable {
    /// Root URL of the package directory
    public let rootURL: URL

    /// Parsed scene configuration
    public let scene: Scene

    /// Map of animation references to their file URLs
    public let animFilesByRef: [String: URL]

    /// Root URL of the images directory (if present)
    public let imagesRootURL: URL?

    public init(
        rootURL: URL,
        scene: Scene,
        animFilesByRef: [String: URL],
        imagesRootURL: URL?
    ) {
        self.rootURL = rootURL
        self.scene = scene
        self.animFilesByRef = animFilesByRef
        self.imagesRootURL = imagesRootURL
    }
}
