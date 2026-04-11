import Foundation
import Metal
import TVECore

// MARK: - Background Texture Service Errors

/// Errors that can occur during background texture operations.
public enum BackgroundTextureError: Error, LocalizedError {
    case imagePersistFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .imagePersistFailed(let error):
            return "Failed to persist background image: \(error.localizedDescription)"
        }
    }
}

// MARK: - Background Texture Service

/// Manages background image textures for the renderer.
///
/// Responsibilities:
/// - Load images from MediaRef (file in app sandbox) via DownsampledImageLoader
/// - Inject textures into MutableTextureProvider
/// - Track loaded slot keys for cleanup on preset change
/// - Persist background images via ImageFilePreparePipeline + ProjectStore
///
/// Model A contract: All state access on @MainActor.
@MainActor
public final class BackgroundTextureService {

    // MARK: - Properties

    private let textureProvider: MutableTextureProvider
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let mediaLocator: any ProjectMediaLocator
    private let mediaWriter: any ProjectMediaWriteGateway

    /// Tracks all currently loaded slot keys for cleanup.
    private var loadedSlotKeys: Set<String> = []

    // MARK: - Initialization

    /// Creates a new BackgroundTextureService.
    ///
    /// - Parameters:
    ///   - textureProvider: Provider for texture injection
    ///   - device: Metal device for texture creation
    ///   - commandQueue: Command queue for texture operations
    ///   - mediaLocator: Locator for resolving MediaRef to absolute URLs
    ///   - mediaWriter: Writer for persisting and deleting media files
    public init(
        textureProvider: MutableTextureProvider,
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        mediaLocator: any ProjectMediaLocator,
        mediaWriter: any ProjectMediaWriteGateway
    ) {
        self.textureProvider = textureProvider
        self.device = device
        self.commandQueue = commandQueue
        self.mediaLocator = mediaLocator
        self.mediaWriter = mediaWriter
    }

    // MARK: - Texture Loading

    /// Loads a texture from a MediaRef and injects it into the provider.
    /// PR4: If file is missing, logs warning and returns (no throw) - renderer will skip draw.
    ///
    /// - Parameters:
    ///   - slotKey: Texture slot key (e.g., "bg/wave_split/top")
    ///   - mediaRef: Reference to the image file
    ///   - assetRegistry: Project asset registry snapshot — the caller passes
    ///     the current draft's registry so the locator can resolve via
    ///     `assetId` → descriptor → `storagePath`. The service holds no
    ///     current-project state.
    /// - Throws: BackgroundTextureError if loading fails (except missing file)
    public func loadTexture(
        slotKey: String,
        mediaRef: MediaRef,
        assetRegistry: ProjectAssetRegistry
    ) async throws {
        // Resolve absolute path via registry-backed locator
        let fileURL = try await mediaLocator.absoluteURL(for: mediaRef, registry: assetRegistry)

        // PR4: Missing file -> log + return (not throw), renderer will skip draw
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            #if DEBUG
            print("[BackgroundTextureService] WARNING: File not found for slot '\(slotKey)': \(fileURL.path)")
            #endif
            return
        }

        // Load texture off-MainActor via DownsampledImageLoader
        let texture = try await Self.loadPreviewTexture(
            fileURL: fileURL, device: device, commandQueue: commandQueue
        )

        // Inject into provider
        textureProvider.setTexture(texture, for: slotKey)
        loadedSlotKeys.insert(slotKey)

        #if DEBUG
        print("[BackgroundTextureService] Loaded texture for slot '\(slotKey)'")
        #endif
    }

    /// Clears a single texture.
    ///
    /// - Parameter slotKey: Texture slot key to clear
    public func clearTexture(slotKey: String) {
        textureProvider.removeTexture(for: slotKey)
        loadedSlotKeys.remove(slotKey)

        #if DEBUG
        print("[BackgroundTextureService] Cleared texture for slot '\(slotKey)'")
        #endif
    }

    /// Clears all textures with a given prefix.
    /// Used when preset changes to remove old preset's textures.
    ///
    /// - Parameter prefix: Slot key prefix (e.g., "bg/wave_split/")
    public func clearTextures(prefix: String) {
        let keysToRemove = loadedSlotKeys.filter { $0.hasPrefix(prefix) }

        for key in keysToRemove {
            textureProvider.removeTexture(for: key)
            loadedSlotKeys.remove(key)
        }

        #if DEBUG
        if !keysToRemove.isEmpty {
            print("[BackgroundTextureService] Cleared \(keysToRemove.count) textures with prefix '\(prefix)'")
        }
        #endif
    }

    /// Clears all loaded textures.
    public func clearAllTextures() {
        for key in loadedSlotKeys {
            textureProvider.removeTexture(for: key)
        }
        loadedSlotKeys.removeAll()

        #if DEBUG
        print("[BackgroundTextureService] Cleared all background textures")
        #endif
    }

    /// PR4: Alias for clearAllTextures - clears all tracked background textures.
    /// Called on PlayerViewController lifecycle (viewDidDisappear/deinit).
    public func clearAllTrackedTextures() {
        clearAllTextures()
    }

    // MARK: - Export Loading

    /// Loads a background texture for export using DownsampledImageLoader.
    ///
    /// Uses Image I/O thumbnail API for memory-efficient downsampling.
    ///
    /// - Parameters:
    ///   - slotKey: Texture slot key (e.g., "bg/wave_split/top")
    ///   - url: Resolved file URL for the background image
    ///   - device: Metal device for texture creation
    ///   - commandQueue: Command queue for staging -> private blit
    ///   - maxDimensionPx: Maximum dimension in pixels (from ExportResourceBudget)
    /// - Throws: DownsampledImageLoader.LoadError if loading fails
    public func loadTextureForExport(
        slotKey: String,
        url: URL,
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        maxDimensionPx: Int
    ) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            #if DEBUG
            print("[BackgroundTextureService] WARNING: File not found for export slot '\(slotKey)': \(url.path)")
            #endif
            return
        }

        let texture = try DownsampledImageLoader.loadTexture(
            from: url,
            device: device,
            commandQueue: commandQueue,
            maxDimensionPx: maxDimensionPx
        )

        textureProvider.setTexture(texture, for: slotKey)
        loadedSlotKeys.insert(slotKey)

        #if DEBUG
        print("[BackgroundTextureService] Loaded export texture for slot '\(slotKey)' (max \(maxDimensionPx)px)")
        #endif
    }

    // MARK: - Image Persistence

    /// Prepares and persists a background image from a source file.
    ///
    /// - Parameter sourceFileURL: Source image file URL (e.g. from PickerAssetAdapter)
    /// - Returns: Tuple of (MediaRef, persisted file URL)
    /// - Throws: BackgroundTextureError.imagePersistFailed if prepare or save fails
    public func persistImage(from sourceFileURL: URL) async throws -> (MediaRef, URL) {
        do {
            return try await Self.prepareAndPersistBackground(
                sourceFileURL: sourceFileURL, mediaWriter: mediaWriter
            )
        } catch {
            throw BackgroundTextureError.imagePersistFailed(error)
        }
    }

    // MARK: - File Cleanup

    /// Deletes a persisted media file via the injected media writer.
    /// Use for orphan cleanup when texture load fails after successful persist.
    public func deleteMediaFile(_ mediaRef: MediaRef) async throws {
        try await mediaWriter.deleteMediaFile(mediaRef)
    }

    // MARK: - Preload

    /// Preloads textures for regions with image overrides.
    ///
    /// - Parameters:
    ///   - override: Project background override with MediaRefs
    ///   - presetId: Current preset ID for slot key generation
    ///   - assetRegistry: Project asset registry snapshot — value-passed by
    ///     the caller so each texture load resolves via the registry-backed
    ///     locator.
    /// - Returns: Set of slot keys that were successfully loaded
    public func preloadTextures(
        from override: ProjectBackgroundOverride,
        presetId: String,
        assetRegistry: ProjectAssetRegistry
    ) async -> Set<String> {
        var loadedKeys: Set<String> = []

        for (regionId, regionOverride) in override.regions {
            if case .image(let imageOverride) = regionOverride.source {
                let slotKey = EffectiveBackgroundBuilder.makeSlotKey(
                    presetId: presetId,
                    regionId: regionId
                )

                do {
                    try await loadTexture(
                        slotKey: slotKey,
                        mediaRef: imageOverride.mediaRef,
                        assetRegistry: assetRegistry
                    )
                    loadedKeys.insert(slotKey)
                } catch {
                    #if DEBUG
                    print("[BackgroundTextureService] Failed to preload texture for '\(slotKey)': \(error.localizedDescription)")
                    #endif
                }
            }
        }

        return loadedKeys
    }

    // MARK: - State Query

    /// Returns all currently loaded slot keys.
    public var allLoadedSlotKeys: Set<String> {
        loadedSlotKeys
    }

    /// Returns whether a slot key is currently loaded.
    public func isLoaded(_ slotKey: String) -> Bool {
        loadedSlotKeys.contains(slotKey)
    }

    // MARK: - Private Helpers

    /// Off-MainActor preview texture load via DownsampledImageLoader.
    /// Pattern: UserMediaService.loadPhotoTexture (line 519)
    private static nonisolated func loadPreviewTexture(
        fileURL: URL,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) async throws -> MTLTexture {
        try DownsampledImageLoader.loadTexture(
            from: fileURL, device: device, commandQueue: commandQueue, maxDimensionPx: 2048
        )
    }

    /// Off-MainActor prepare + persist via ImageFilePreparePipeline + media writer.
    private static nonisolated func prepareAndPersistBackground(
        sourceFileURL: URL,
        mediaWriter: any ProjectMediaWriteGateway
    ) async throws -> (MediaRef, URL) {
        let preparedURL = try ImageFilePreparePipeline.prepareJPEG(
            fileURL: sourceFileURL, maxDimension: 2048, jpegQuality: 0.9
        )
        defer { try? FileManager.default.removeItem(at: preparedURL) }
        return try await mediaWriter.saveBackgroundImage(from: preparedURL)
    }
}
