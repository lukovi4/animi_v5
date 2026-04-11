import Foundation

/// A pre-resolved mapping from logical asset identity to a concrete file URL.
///
/// Built asynchronously via `ResolvedMediaMapBuilder` before entering a
/// synchronous apply path. This keeps URL resolution off the runtime/composition
/// layer, so that composition code never constructs a `FileProjectMediaStore`
/// directly and never touches the file system to turn an `assetId` into a path.
///
/// Missing entries are expected: the caller is responsible for marking the
/// corresponding block as restore-failed (see `MediaRestoreCoordinator`).
public struct ResolvedMediaMap: Sendable {
    private let urls: [ProjectAssetID: URL]

    public init(urlsByAssetId: [ProjectAssetID: URL] = [:]) {
        self.urls = urlsByAssetId
    }

    public init(_ urls: [ProjectAssetID: URL]) {
        self.urls = urls
    }

    public static let empty = ResolvedMediaMap(urlsByAssetId: [:])

    public func url(for mediaRef: MediaRef) -> URL? {
        urls[mediaRef.assetId]
    }

    public func url(for assetId: ProjectAssetID) -> URL? {
        urls[assetId]
    }

    public var isEmpty: Bool { urls.isEmpty }
}

/// Builds a `ResolvedMediaMap` from a collection of media slots by asking
/// the injected `ProjectMediaLocator` to resolve each `MediaRef` against an
/// explicit `ProjectAssetRegistry` snapshot.
///
/// The registry snapshot is **required**: it is how the locator turns a
/// logical `assetId` into a concrete file. Callers pass the current draft's
/// registry (`session.currentDraftSnapshot?.assetRegistry ?? .init()`).
///
/// Best-effort: any slot whose URL cannot be resolved is simply omitted from
/// the map. Callers (e.g. `MediaRestoreCoordinator.restore`) must handle
/// missing URLs explicitly (mark as failed, etc.).
public enum ResolvedMediaMapBuilder {
    public static func build(
        slots: [String: SceneMediaSlot]?,
        locator: any ProjectMediaLocator,
        registry: ProjectAssetRegistry
    ) async -> ResolvedMediaMap {
        guard let slots, !slots.isEmpty else { return .empty }

        var resolved: [ProjectAssetID: URL] = [:]
        resolved.reserveCapacity(slots.count)

        for (_, slot) in slots {
            let assetId = slot.mediaRef.assetId
            if resolved[assetId] != nil { continue }
            do {
                let url = try await locator.absoluteURL(for: slot.mediaRef, registry: registry)
                resolved[assetId] = url
            } catch {
                // Intentionally swallowed — caller detects the missing entry.
                #if DEBUG
                print("[ResolvedMediaMapBuilder] failed to resolve asset \(assetId.rawValue): \(error)")
                #endif
            }
        }

        return ResolvedMediaMap(urlsByAssetId: resolved)
    }
}
