import Foundation

/// Protocol for resolving media file URLs from persistent references.
///
/// Resolution is **registry-backed**: the caller passes a
/// `ProjectAssetRegistry` snapshot so the locator can look up the concrete
/// `storagePath` for `mediaRef.assetId`. This decouples asset identity from
/// the file layout and keeps the locator free of any global "current project"
/// state.
///
/// Fallback to `mediaRef.storagePath` is a legacy-only compatibility path
/// (pre-registry drafts, bootstrap, standalone export) handled inside the
/// concrete implementation on registry miss. Production runtime / composition
/// / export must always pass a populated registry.
public protocol ProjectMediaLocator: Sendable {
    /// Canonical API: resolves a `MediaRef` using the given registry snapshot.
    ///
    /// Conforming types are responsible for looking up `mediaRef.assetId` in
    /// the registry, and for handling the legacy-fallback case when the
    /// registry has no descriptor.
    func absoluteURL(for mediaRef: MediaRef, registry: ProjectAssetRegistry) async throws -> URL
}
