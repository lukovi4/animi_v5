import UIKit
import Metal
import TVECore

// MARK: - Background Texture Service Errors

/// Errors that can occur during background texture operations.
public enum BackgroundTextureError: Error, LocalizedError {
    case fileNotFound(path: String)
    case imageLoadFailed(path: String)
    case textureCreationFailed(slotKey: String)
    case imageSaveFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Background image file not found: \(path)"
        case .imageLoadFailed(let path):
            return "Failed to load background image: \(path)"
        case .textureCreationFailed(let slotKey):
            return "Failed to create texture for slot: \(slotKey)"
        case .imageSaveFailed(let error):
            return "Failed to save background image: \(error.localizedDescription)"
        }
    }
}

// MARK: - Background Texture Service

/// Manages background image textures for the renderer.
///
/// Responsibilities:
/// - Load images from MediaRef (file in app sandbox)
/// - Create Metal textures via UserMediaTextureFactory
/// - Inject textures into MutableTextureProvider
/// - Track loaded slot keys for cleanup on preset change
///
/// Model A contract: All state access on @MainActor.
@MainActor
public final class BackgroundTextureService {

    // MARK: - Properties

    private let textureProvider: MutableTextureProvider
    private let textureFactory: UserMediaTextureFactory
    private let projectStore: ProjectStore

    /// Tracks all currently loaded slot keys for cleanup.
    private var loadedSlotKeys: Set<String> = []

    // MARK: - Initialization

    /// Creates a new BackgroundTextureService.
    ///
    /// - Parameters:
    ///   - textureProvider: Provider for texture injection
    ///   - device: Metal device for texture creation
    ///   - commandQueue: Command queue for texture operations
    ///   - projectStore: Store for resolving MediaRef paths
    public init(
        textureProvider: MutableTextureProvider,
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        projectStore: ProjectStore = .shared
    ) {
        self.textureProvider = textureProvider
        self.textureFactory = UserMediaTextureFactory(device: device, commandQueue: commandQueue)
        self.projectStore = projectStore
    }

    // MARK: - Texture Loading

    /// Loads a texture from a MediaRef and injects it into the provider.
    /// PR4: If file is missing, logs warning and returns (no throw) - renderer will skip draw.
    ///
    /// - Parameters:
    ///   - slotKey: Texture slot key (e.g., "bg/wave_split/top")
    ///   - mediaRef: Reference to the image file
    /// - Throws: BackgroundTextureError if loading fails (except missing file)
    public func loadTexture(slotKey: String, mediaRef: MediaRef) async throws {
        // Resolve absolute path
        let fileURL = try projectStore.absoluteURL(for: mediaRef)

        // PR4: Missing file → log + return (not throw), renderer will skip draw
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            #if DEBUG
            print("[BackgroundTextureService] WARNING: File not found for slot '\(slotKey)': \(fileURL.path)")
            #endif
            return
        }

        // Load image data on background thread
        let image: UIImage = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let data = try? Data(contentsOf: fileURL),
                      let image = UIImage(data: data) else {
                    continuation.resume(throwing: BackgroundTextureError.imageLoadFailed(path: fileURL.path))
                    return
                }
                continuation.resume(returning: image)
            }
        }

        // Create texture on main thread
        guard let texture = textureFactory.makeTexture(from: image) else {
            throw BackgroundTextureError.textureCreationFailed(slotKey: slotKey)
        }

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

    // MARK: - Image Saving

    /// Saves an image to the project store and returns a MediaRef.
    ///
    /// - Parameters:
    ///   - image: Image to save
    ///   - maxDimension: Maximum dimension for resizing (default: 2048)
    ///   - jpegQuality: JPEG compression quality (default: 0.9)
    /// - Returns: MediaRef pointing to the saved file
    /// - Throws: BackgroundTextureError if saving fails
    public func saveImage(
        _ image: UIImage,
        maxDimension: CGFloat = 2048,
        jpegQuality: CGFloat = 0.9
    ) throws -> MediaRef {
        // Resize if needed
        let resizedImage = resizeImageIfNeeded(image, maxDimension: maxDimension)

        // Convert to JPEG data
        guard let jpegData = resizedImage.jpegData(compressionQuality: jpegQuality) else {
            throw BackgroundTextureError.imageSaveFailed(
                NSError(domain: "BackgroundTextureService", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to create JPEG data"
                ])
            )
        }

        // Save to project store
        do {
            return try projectStore.saveBackgroundImage(jpegData)
        } catch {
            throw BackgroundTextureError.imageSaveFailed(error)
        }
    }

    // MARK: - Preload

    /// Preloads all image textures from an effective background state.
    ///
    /// - Parameter state: Background state with region configurations
    /// - Returns: Set of slot keys that were successfully loaded
    public func preloadTextures(from state: EffectiveBackgroundState) async -> Set<String> {
        var loadedKeys: Set<String> = []

        for (regionId, regionState) in state.regionStates {
            if case .image(let imageConfig) = regionState.source {
                // Extract MediaRef from project override
                // Note: The actual MediaRef lookup happens in caller context
                // because EffectiveBackgroundState doesn't store MediaRef
                loadedKeys.insert(imageConfig.slotKey)
            }
        }

        return loadedKeys
    }

    /// Preloads textures for regions with image overrides.
    ///
    /// - Parameters:
    ///   - override: Project background override with MediaRefs
    ///   - presetId: Current preset ID for slot key generation
    /// - Returns: Set of slot keys that were successfully loaded
    public func preloadTextures(
        from override: ProjectBackgroundOverride,
        presetId: String
    ) async -> Set<String> {
        var loadedKeys: Set<String> = []

        for (regionId, regionOverride) in override.regions {
            if case .image(let imageOverride) = regionOverride.source {
                let slotKey = EffectiveBackgroundBuilder.makeSlotKey(
                    presetId: presetId,
                    regionId: regionId
                )

                do {
                    try await loadTexture(slotKey: slotKey, mediaRef: imageOverride.mediaRef)
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

    // MARK: - Private Helpers

    /// Resizes image if it exceeds the maximum dimension.
    private func resizeImageIfNeeded(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size

        guard size.width > maxDimension || size.height > maxDimension else {
            return image
        }

        let scale = min(maxDimension / size.width, maxDimension / size.height)
        let newSize = CGSize(
            width: size.width * scale,
            height: size.height * scale
        )

        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        defer { UIGraphicsEndImageContext() }

        image.draw(in: CGRect(origin: .zero, size: newSize))
        return UIGraphicsGetImageFromCurrentImageContext() ?? image
    }

    // MARK: - File Cleanup

    /// Deletes the media file for a MediaRef from disk.
    /// P1-3: Called after successful texture inject when replacing an image.
    ///
    /// - Parameter mediaRef: Reference to the media file to delete
    public func deleteMediaFile(_ mediaRef: MediaRef) {
        do {
            let fileURL = try projectStore.absoluteURL(for: mediaRef)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
                #if DEBUG
                print("[BackgroundTextureService] Deleted media file: \(mediaRef.id)")
                #endif
            }
        } catch {
            #if DEBUG
            print("[BackgroundTextureService] Failed to delete media file \(mediaRef.id): \(error.localizedDescription)")
            #endif
        }
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
}
