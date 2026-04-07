import Foundation
import TVECore

/// Abstracts access to the background preset library for feature controllers.
/// Feature code depends on this protocol, not on `BackgroundPresetLibrary.shared`.
public protocol BackgroundPresetProviding {
    func loadFromBundle() throws
    func preset(for presetId: String) -> BackgroundPreset?
    func presetOrFallback(for presetId: String) -> BackgroundPreset?
    var allPresets: [BackgroundPreset] { get }
    var count: Int { get }
}

/// Singleton-backed implementation. The singleton lives inside this adapter only.
final class BackgroundPresetRepository: BackgroundPresetProviding {

    private let library: BackgroundPresetLibrary

    init(library: BackgroundPresetLibrary = .shared) {
        self.library = library
    }

    func loadFromBundle() throws {
        try library.loadFromBundle()
    }

    func preset(for presetId: String) -> BackgroundPreset? {
        library.preset(for: presetId)
    }

    func presetOrFallback(for presetId: String) -> BackgroundPreset? {
        library.presetOrFallback(for: presetId)
    }

    var allPresets: [BackgroundPreset] {
        library.allPresets
    }

    var count: Int {
        library.count
    }
}
