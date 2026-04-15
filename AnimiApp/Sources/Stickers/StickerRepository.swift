import Foundation

/// Abstracts access to the sticker library for feature controllers.
/// Feature code depends on this protocol, not on `StickerLibrary.shared`.
public protocol StickerProviding {
    func loadFromBundle() throws
    func descriptor(for stickerId: String) -> StickerDescriptor?
    func resourceURL(for stickerId: String) -> URL?
    var allDescriptors: [StickerDescriptor] { get }
    var count: Int { get }
}

/// Singleton-backed implementation. The singleton lives inside this adapter only.
final class StickerRepository: StickerProviding {

    private let library: StickerLibrary

    init(library: StickerLibrary) {
        self.library = library
    }

    convenience init() {
        self.init(library: .shared)
    }

    func loadFromBundle() throws {
        try library.loadFromBundle()
    }

    func descriptor(for stickerId: String) -> StickerDescriptor? {
        library.descriptor(for: stickerId)
    }

    func resourceURL(for stickerId: String) -> URL? {
        library.resourceURL(for: stickerId)
    }

    var allDescriptors: [StickerDescriptor] {
        library.allDescriptors
    }

    var count: Int {
        library.count
    }
}
