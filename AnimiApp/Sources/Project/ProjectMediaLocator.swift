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

public extension ProjectMediaLocator {
    /// Deprecated compatibility wrapper — equivalent to calling the canonical
    /// API with an empty registry, which forces the concrete implementation
    /// into its legacy/storagePath fallback branch.
    ///
    /// - Important: Transitional bridge. Do not use on production runtime /
    ///   composition / export call sites after PR5 Phase D. Phase G verifies.
    @available(*, deprecated, message: "Pass a ProjectAssetRegistry snapshot explicitly via absoluteURL(for:registry:)")
    func absoluteURL(for mediaRef: MediaRef) async throws -> URL {
        try await absoluteURL(for: mediaRef, registry: ProjectAssetRegistry())
    }
}
