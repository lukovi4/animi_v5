import XCTest
import Metal
import TVECore
@testable import AnimiApp

/// PR5 Phase G §9.7: Proves the production runtime/background/media-ingest
/// seams resolve media exclusively through their injected
/// `ProjectMediaLocator` / `ProjectMediaWriteGateway` dependencies, and
/// never reach for a raw `ProjectStore` / `FileProjectMediaStore`.
///
/// Covers:
/// - `BackgroundTextureService.loadTexture(slotKey:mediaRef:assetRegistry:)`
/// - `MediaAssetStore.saveMedia(...)` routes through the injected
///   `ProjectMediaWriteGateway`.
/// - `ResolvedMediaMapBuilder.build(slots:locator:registry:)` — the async
///   pre-resolve path used by `SceneInstanceRuntime.applyState` and
///   `PlayerViewController.applySceneInstanceState`.
@MainActor
final class RuntimeStorageBoundaryTests: XCTestCase {

    // MARK: - Spies

    /// Spy that counts calls and records the assetIds/registries it was given.
    final class SpyLocator: ProjectMediaLocator, @unchecked Sendable {
        private let resolver: (MediaRef) -> URL

        private(set) var callCount: Int = 0
        private(set) var requestedAssetIds: [ProjectAssetID] = []
        private(set) var registryDescriptorHitCount: Int = 0

        init(resolver: @escaping (MediaRef) -> URL = { _ in URL(fileURLWithPath: "/tmp/spy-stub") }) {
            self.resolver = resolver
        }

        func absoluteURL(for mediaRef: MediaRef, registry: ProjectAssetRegistry) async throws -> URL {
            callCount += 1
            requestedAssetIds.append(mediaRef.assetId)
            if registry.descriptor(for: mediaRef.assetId) != nil {
                registryDescriptorHitCount += 1
            }
            return resolver(mediaRef)
        }
    }

    /// Throwing spy: proves fast-path code never reaches URL resolution.
    struct ThrowingSpyLocator: ProjectMediaLocator {
        func absoluteURL(for mediaRef: MediaRef, registry: ProjectAssetRegistry) async throws -> URL {
            throw NSError(
                domain: "ThrowingSpyLocator",
                code: 99,
                userInfo: [NSLocalizedDescriptionKey: "Fast path must not touch the locator"]
            )
        }
    }

    /// Spy write gateway that counts `saveUserMedia` / `deleteMediaFile` calls.
    final class SpyMediaWriter: ProjectMediaWriteGateway, @unchecked Sendable {
        private(set) var saveUserMediaCallCount: Int = 0
        private(set) var saveBackgroundImageCallCount: Int = 0
        private(set) var deleteMediaFileCallCount: Int = 0
        private(set) var lastSavedFilename: String?
        private(set) var lastSavedMediaKind: MediaKind?

        func saveBackgroundImage(from preparedFileURL: URL) async throws -> (MediaRef, URL) {
            saveBackgroundImageCallCount += 1
            let ref = MediaRef(storagePath: "Media/Background/stub.jpg", mediaKind: .photo)
            return (ref, URL(fileURLWithPath: "/tmp/stub-bg.jpg"))
        }

        func saveUserMedia(from fileURL: URL, mediaKind: MediaKind, filename: String) async throws -> (MediaRef, URL) {
            saveUserMediaCallCount += 1
            lastSavedFilename = filename
            lastSavedMediaKind = mediaKind
            let ref = MediaRef(storagePath: "Media/UserMedia/\(filename)", mediaKind: mediaKind)
            return (ref, URL(fileURLWithPath: "/tmp/\(filename)"))
        }

        func deleteMediaFile(_ mediaRef: MediaRef) async throws {
            deleteMediaFileCallCount += 1
        }

        func duplicateAssets(inDraft sourceDraft: ProjectDraft) async throws -> ProjectDraft {
            sourceDraft
        }
    }

    // MARK: - MediaAssetStore routes via injected writer

    func test_mediaAssetStore_saveMedia_routesThroughInjectedWriter() async throws {
        let spy = SpyMediaWriter()
        let store = MediaAssetStore(mediaWriter: spy)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pr5G_\(UUID().uuidString).jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let sceneId = UUID()
        let blockId = "block1"
        let (ref, _) = try await store.saveMedia(
            from: tempURL,
            mediaKind: .photo,
            sceneInstanceId: sceneId,
            blockId: blockId
        )

        XCTAssertEqual(spy.saveUserMediaCallCount, 1, "saveMedia must delegate to mediaWriter.saveUserMedia")
        XCTAssertEqual(spy.lastSavedMediaKind, .photo)
        XCTAssertEqual(ref.mediaKind, .photo)
        // The spy's generated filename embeds sceneId + blockId.
        XCTAssertTrue(spy.lastSavedFilename?.contains(sceneId.uuidString) == true)
        XCTAssertTrue(spy.lastSavedFilename?.contains(blockId) == true)
    }

    // MARK: - ResolvedMediaMapBuilder uses only the injected locator

    func test_resolvedMediaMapBuilder_usesInjectedLocator_withRegistry() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pr5G_runtime_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let assetId = ProjectAssetID()
        let mediaRef = MediaRef(storagePath: "Media/UserMedia/x.jpg", mediaKind: .photo, assetId: assetId)

        var registry = ProjectAssetRegistry()
        registry.register(ProjectAssetDescriptor(
            assetId: assetId,
            mediaKind: .photo,
            storagePath: "Media/UserMedia/x.jpg"
        ))

        let spy = SpyLocator(resolver: { ref in
            tempDir.appendingPathComponent(ref.storagePath)
        })

        let slots: [String: SceneMediaSlot] = [
            "block1": .photo(mediaRef: mediaRef, placement: .defaultCover)
        ]

        let map = await ResolvedMediaMapBuilder.build(
            slots: slots,
            locator: spy,
            registry: registry
        )

        XCTAssertEqual(spy.callCount, 1, "Builder must call the spy exactly once per unique assetId")
        XCTAssertEqual(spy.requestedAssetIds, [assetId])
        XCTAssertEqual(
            spy.registryDescriptorHitCount,
            1,
            "Builder must pass the populated registry so the locator hits a descriptor"
        )
        XCTAssertNotNil(map.url(for: mediaRef))
    }

    /// De-duplication: two slots with the same `assetId` must only ping the
    /// locator once — builder caches by assetId.
    func test_resolvedMediaMapBuilder_deduplicatesBySameAssetId() async throws {
        let sharedId = ProjectAssetID()
        let ref1 = MediaRef(storagePath: "Media/UserMedia/a.jpg", mediaKind: .photo, assetId: sharedId)
        let ref2 = MediaRef(storagePath: "Media/UserMedia/a.jpg", mediaKind: .photo, assetId: sharedId)

        let slots: [String: SceneMediaSlot] = [
            "block1": .photo(mediaRef: ref1, placement: .defaultCover),
            "block2": .photo(mediaRef: ref2, placement: .defaultCover),
        ]

        let spy = SpyLocator()
        _ = await ResolvedMediaMapBuilder.build(
            slots: slots,
            locator: spy,
            registry: ProjectAssetRegistry()
        )

        XCTAssertEqual(spy.callCount, 1, "Two slots sharing an assetId must hit the locator once")
    }

    // MARK: - BackgroundTextureService uses injected locator only

    /// `BackgroundTextureService.loadTexture(...)` routes through the injected
    /// `ProjectMediaLocator`, passing the supplied registry snapshot.
    func test_backgroundTextureService_loadTexture_routesThroughInjectedLocator() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device not available")
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pr5G_bg_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Write a real image the DownsampledImageLoader can open.
        let relativePath = "Media/Background/real.jpg"
        let fileURL = tempDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.writeRealJPEG(at: fileURL, width: 32, height: 32)

        let assetId = ProjectAssetID()
        let mediaRef = MediaRef(storagePath: relativePath, mediaKind: .photo, assetId: assetId)
        var registry = ProjectAssetRegistry()
        registry.register(ProjectAssetDescriptor(
            assetId: assetId,
            mediaKind: .photo,
            storagePath: relativePath
        ))

        let spy = SpyLocator(resolver: { _ in fileURL })
        let writer = SpyMediaWriter()
        let provider = InMemoryTextureProvider()
        let service = BackgroundTextureService(
            textureProvider: provider,
            device: device,
            commandQueue: commandQueue,
            mediaLocator: spy,
            mediaWriter: writer
        )

        try await service.loadTexture(
            slotKey: "bg/test/region",
            mediaRef: mediaRef,
            assetRegistry: registry
        )

        XCTAssertEqual(spy.callCount, 1, "BackgroundTextureService must resolve via the injected locator")
        XCTAssertEqual(
            spy.registryDescriptorHitCount,
            1,
            "BackgroundTextureService must pass the live registry (descriptor hit)"
        )
    }

    // MARK: - Helpers

    private static func writeRealJPEG(at url: URL, width: Int, height: Int) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ), let cgImage = ctx.makeImage() else {
            throw NSError(domain: "JPEGHelper", code: -1)
        }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "JPEGHelper", code: -2)
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "JPEGHelper", code: -3)
        }
    }
}

#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
