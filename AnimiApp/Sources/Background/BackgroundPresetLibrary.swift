import Foundation
import TVECore

// MARK: - Preset Library Errors

/// Errors that can occur when loading background presets from bundle.
public enum PresetLibraryError: Error, LocalizedError {
    case indexNotFound
    case presetFileNotFound(presetId: String)
    case decodingFailed(presetId: String, error: Error)

    public var errorDescription: String? {
        switch self {
        case .indexNotFound:
            return "presets_index.json not found in BackgroundPresets"
        case .presetFileNotFound(let presetId):
            return "Preset file not found: bg_\(presetId).json"
        case .decodingFailed(let presetId, let error):
            return "Failed to decode preset '\(presetId)': \(error.localizedDescription)"
        }
    }
}

// MARK: - Presets Index

/// Index file structure for presets_index.json
struct PresetsIndex: Codable {
    /// List of preset IDs to load
    let presetIds: [String]
}

// MARK: - Background Preset Library

/// Singleton library for accessing background presets from the app bundle.
/// Presets are stored as JSON files in Resources/BackgroundPresets/.
public final class BackgroundPresetLibrary {

    // MARK: - Singleton

    /// Shared instance of the preset library.
    public static let shared = BackgroundPresetLibrary()

    // MARK: - Properties

    private let bundle: Bundle
    private var presets: [String: BackgroundPreset] = [:]
    private var presetOrder: [String] = []
    private var isLoaded = false

    // MARK: - Initialization

    /// Creates a preset library using the specified bundle.
    /// - Parameter bundle: Bundle to load presets from (default: .main)
    public init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    // MARK: - Public API

    /// Loads all presets from the bundle. Call this once at app startup.
    /// - Throws: `PresetLibraryError` if loading fails.
    public func loadFromBundle() throws {
        guard !isLoaded else { return }

        // Load presets_index.json
        guard let indexURL = bundle.url(
            forResource: "presets_index",
            withExtension: "json",
            subdirectory: "BackgroundPresets"
        ) else {
            #if DEBUG
            print("[BackgroundPresets] ERROR: presets_index.json not found")
            #endif
            throw PresetLibraryError.indexNotFound
        }

        #if DEBUG
        print("[BackgroundPresets] Found index at: \(indexURL.path)")
        #endif

        let indexData = try Data(contentsOf: indexURL)
        let index = try JSONDecoder().decode(PresetsIndex.self, from: indexData)

        // Load each preset
        for presetId in index.presetIds {
            let preset = try loadPreset(presetId: presetId)
            presets[presetId] = preset
            presetOrder.append(presetId)

            #if DEBUG
            print("[BackgroundPresets] Loaded preset: \(presetId) (\(preset.regions.count) regions)")
            #endif
        }

        isLoaded = true

        #if DEBUG
        print("[BackgroundPresets] Loaded \(presets.count) presets")
        #endif
    }

    /// Returns the preset with the given ID.
    /// - Parameter presetId: The preset identifier.
    /// - Returns: The preset, or nil if not found.
    public func preset(for presetId: String) -> BackgroundPreset? {
        return presets[presetId]
    }

    /// Returns all loaded presets in display order.
    public var allPresets: [BackgroundPreset] {
        return presetOrder.compactMap { presets[$0] }
    }

    /// Returns the number of loaded presets.
    public var count: Int {
        return presets.count
    }

    /// Returns the fallback preset ID for unknown/missing presets.
    public static let fallbackPresetId = "solid_fullscreen"

    /// Returns a preset by ID, or the fallback preset if not found.
    /// - Parameter presetId: The preset identifier.
    /// - Returns: The requested preset or the fallback preset.
    public func presetOrFallback(for presetId: String) -> BackgroundPreset? {
        return preset(for: presetId) ?? preset(for: Self.fallbackPresetId)
    }

    // MARK: - Private Helpers

    private func loadPreset(presetId: String) throws -> BackgroundPreset {
        guard let presetURL = bundle.url(
            forResource: "bg_\(presetId)",
            withExtension: "json",
            subdirectory: "BackgroundPresets"
        ) else {
            throw PresetLibraryError.presetFileNotFound(presetId: presetId)
        }

        let data = try Data(contentsOf: presetURL)
        do {
            return try JSONDecoder().decode(BackgroundPreset.self, from: data)
        } catch {
            throw PresetLibraryError.decodingFailed(presetId: presetId, error: error)
        }
    }

    // MARK: - Testing Support

    /// Resets the library state (for testing).
    internal func reset() {
        presets.removeAll()
        presetOrder.removeAll()
        isLoaded = false
    }

    /// Manually registers a preset (for testing).
    internal func register(_ preset: BackgroundPreset) {
        presets[preset.presetId] = preset
        if !presetOrder.contains(preset.presetId) {
            presetOrder.append(preset.presetId)
        }
        isLoaded = true
    }
}
