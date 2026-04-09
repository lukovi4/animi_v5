import Foundation

/// Protocol for resolving media file URLs from persistent references.
protocol ProjectMediaLocator: Sendable {
    func absoluteURL(for mediaRef: MediaRef) async throws -> URL
}
