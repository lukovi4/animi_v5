import Foundation

// MARK: - Sticker Descriptor

/// Describes a bundled sticker asset.
public struct StickerDescriptor: Codable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let filename: String
}

// MARK: - Sticker Library Errors

public enum StickerLibraryError: Error, LocalizedError {
    case indexNotFound
    case decodingFailed(Error)
    case stickerFileNotFound(stickerId: String, filename: String)

    public var errorDescription: String? {
        switch self {
        case .indexNotFound:
            return "stickers_index.json not found in Stickers"
        case .decodingFailed(let error):
            return "Failed to decode stickers index: \(error.localizedDescription)"
        case .stickerFileNotFound(let stickerId, let filename):
            return "Sticker file not found: \(filename) (id: \(stickerId))"
        }
    }
}

// MARK: - Sticker Library

/// Singleton library for accessing bundled sticker assets.
/// Stickers are stored as PNG files in Resources/Stickers/.
/// Catalog is driven by stickers_index.json — adding a sticker = adding a PNG + JSON entry.
public final class StickerLibrary {

    // MARK: - Singleton

    public static let shared = StickerLibrary()

    // MARK: - Properties

    private let bundle: Bundle
    private var descriptors: [String: StickerDescriptor] = [:]
    private var descriptorOrder: [String] = []
    private var isLoaded = false

    // MARK: - Initialization

    public init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    // MARK: - Public API

    /// Loads all sticker descriptors from the bundle. Call once at app startup.
    public func loadFromBundle() throws {
        guard !isLoaded else { return }

        guard let indexURL = bundle.url(
            forResource: "stickers_index",
            withExtension: "json",
            subdirectory: "Stickers"
        ) else {
            throw StickerLibraryError.indexNotFound
        }

        let indexData = try Data(contentsOf: indexURL)
        let entries: [StickerDescriptor]
        do {
            entries = try JSONDecoder().decode([StickerDescriptor].self, from: indexData)
        } catch {
            throw StickerLibraryError.decodingFailed(error)
        }

        // Validate all referenced files exist before committing state
        for entry in entries {
            let name = (entry.filename as NSString).deletingPathExtension
            let ext = (entry.filename as NSString).pathExtension
            guard bundle.url(forResource: name, withExtension: ext, subdirectory: "Stickers") != nil else {
                throw StickerLibraryError.stickerFileNotFound(stickerId: entry.id, filename: entry.filename)
            }
        }

        for entry in entries {
            descriptors[entry.id] = entry
            descriptorOrder.append(entry.id)
        }

        isLoaded = true

        #if DEBUG
        print("[StickerLibrary] Loaded \(descriptors.count) stickers")
        #endif
    }

    /// Returns the descriptor for a given sticker ID.
    public func descriptor(for stickerId: String) -> StickerDescriptor? {
        descriptors[stickerId]
    }

    /// Returns the bundle resource URL for a sticker's image.
    public func resourceURL(for stickerId: String) -> URL? {
        guard let desc = descriptors[stickerId] else { return nil }
        let name = (desc.filename as NSString).deletingPathExtension
        let ext = (desc.filename as NSString).pathExtension
        return bundle.url(forResource: name, withExtension: ext, subdirectory: "Stickers")
    }

    /// All sticker descriptors in display order.
    public var allDescriptors: [StickerDescriptor] {
        descriptorOrder.compactMap { descriptors[$0] }
    }

    /// Number of loaded stickers.
    public var count: Int {
        descriptors.count
    }

    // MARK: - Testing Support

    /// Resets the library state (for testing).
    internal func reset() {
        descriptors.removeAll()
        descriptorOrder.removeAll()
        isLoaded = false
    }

    /// Manually registers a descriptor and URL (for testing).
    internal func register(_ descriptor: StickerDescriptor) {
        descriptors[descriptor.id] = descriptor
        if !descriptorOrder.contains(descriptor.id) {
            descriptorOrder.append(descriptor.id)
        }
        isLoaded = true
    }
}
