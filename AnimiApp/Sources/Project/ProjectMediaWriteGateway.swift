import Foundation

/// Protocol for writing media files to project storage.
protocol ProjectMediaWriteGateway: Sendable {
    func saveBackgroundImage(from preparedFileURL: URL) async throws -> (MediaRef, URL)
    func deleteMediaFile(_ mediaRef: MediaRef) async throws
}
