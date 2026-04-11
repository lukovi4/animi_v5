import Foundation

/// Protocol for writing media files to project storage.
public protocol ProjectMediaWriteGateway: Sendable {
    func saveBackgroundImage(from preparedFileURL: URL) async throws -> (MediaRef, URL)
    func saveUserMedia(from fileURL: URL, mediaKind: MediaKind, filename: String) async throws -> (MediaRef, URL)
    func deleteMediaFile(_ mediaRef: MediaRef) async throws

    /// Duplicate-foundation (PR5): copies every asset referenced by
    /// `sourceDraft` to new files with freshly generated `ProjectAssetID`s,
    /// rewrites every `MediaRef` in the draft's slots and background regions
    /// to the new IDs / paths, and returns a rebound draft whose
    /// `assetRegistry` contains only the new descriptors.
    ///
    /// Guarantees:
    /// - The returned draft shares **zero** `assetId`s with `sourceDraft`.
    /// - The returned draft shares **zero** `storagePath`s with `sourceDraft`.
    /// - Source files remain on disk — duplication is a copy, not a move.
    ///
    /// No UI is wired in PR5; this is the storage-level foundation that PR7's
    /// "Duplicate project" action will call.
    func duplicateAssets(inDraft sourceDraft: ProjectDraft) async throws -> ProjectDraft
}
