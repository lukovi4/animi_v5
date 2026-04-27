import XCTest
import Metal
import ImageIO
import TVECore
@testable import AnimiApp

/// Tests for BackgroundTextureService (Phase 7 — file-based pipeline).
@MainActor
final class BackgroundTextureServiceTests: XCTestCase {

    // MARK: - persistImage

    func test_persistImage_fromSourceFile_persistsJPEGUnderBackgroundMediaDir() async throws {
        let tempURL = try createTestImageFile(width: 200, height: 100)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal not available")
        }

        let provider = InMemoryTextureProvider()
        let service = BackgroundTextureService(
            textureProvider: provider,
            device: device,
            commandQueue: commandQueue,
            mediaLocator: ProjectStore(),
            mediaWriter: StubMediaWriter()
        )

        let (mediaRef, persistedURL) = try await service.persistImage(from: tempURL)

        // File persisted on disk
        XCTAssertTrue(FileManager.default.fileExists(atPath: persistedURL.path), "Persisted file should exist")
        // Extension is .jpg
        XCTAssertEqual(persistedURL.pathExtension, "jpg")
        // MediaRef path contains background directory
        XCTAssertTrue(mediaRef.storagePath.contains("Background"), "MediaRef path should include Background directory")
        // MediaRef kind is photo
        XCTAssertEqual(mediaRef.mediaKind, .photo)

        // Cleanup
        try? FileManager.default.removeItem(at: persistedURL)
    }

    func test_persistImage_largeSource_isDownsampledTo2048() async throws {
        // Create a 4000x3000 image — should be downsampled to max 2048
        let tempURL = try createTestImageFile(width: 4000, height: 3000)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal not available")
        }

        let provider = InMemoryTextureProvider()
        let service = BackgroundTextureService(
            textureProvider: provider,
            device: device,
            commandQueue: commandQueue,
            mediaLocator: ProjectStore(),
            mediaWriter: StubMediaWriter()
        )

        let (_, persistedURL) = try await service.persistImage(from: tempURL)
        defer { try? FileManager.default.removeItem(at: persistedURL) }

        // Read back the persisted file and check dimensions
        guard let imageSource = CGImageSourceCreateWithURL(persistedURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            XCTFail("Could not read persisted image properties")
            return
        }

        let longestSide = max(width, height)
        XCTAssertLessThanOrEqual(longestSide, 2048, "Longest side should be ≤ 2048 after downsample")
    }

    // MARK: - loadTexture

    func test_loadTexture_fromPersistedFile_tracksLoadedSlotKey() async throws {
        let tempURL = try createTestImageFile(width: 100, height: 100)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal not available")
        }

        let provider = InMemoryTextureProvider()
        let service = BackgroundTextureService(
            textureProvider: provider,
            device: device,
            commandQueue: commandQueue,
            mediaLocator: ProjectStore(),
            mediaWriter: StubMediaWriter()
        )

        let (mediaRef, persistedURL) = try await service.persistImage(from: tempURL)
        defer { try? FileManager.default.removeItem(at: persistedURL) }

        let slotKey = "bg/test/region"
        try await service.loadTexture(slotKey: slotKey, mediaRef: mediaRef, assetRegistry: ProjectAssetRegistry())

        XCTAssertTrue(service.isLoaded(slotKey), "Slot key should be tracked after load")
        XCTAssertTrue(service.allLoadedSlotKeys.contains(slotKey))
        XCTAssertNotNil(provider.texture(for: slotKey), "Texture should be injected into provider")
    }

    func test_loadTexture_missingFile_doesNotTrackSlotKey() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal not available")
        }

        let provider = InMemoryTextureProvider()
        let service = BackgroundTextureService(
            textureProvider: provider,
            device: device,
            commandQueue: commandQueue,
            mediaLocator: ProjectStore(),
            mediaWriter: StubMediaWriter()
        )

        // Create a MediaRef pointing to a nonexistent file
        let mediaRef = MediaRef.file("media/background/nonexistent.jpg", mediaKind: .photo)
        let slotKey = "bg/test/missing"

        // Should NOT throw — just log and return
        try await service.loadTexture(slotKey: slotKey, mediaRef: mediaRef, assetRegistry: ProjectAssetRegistry())

        XCTAssertFalse(service.isLoaded(slotKey), "Slot key should NOT be tracked for missing file")
        XCTAssertNil(provider.texture(for: slotKey), "No texture should be injected for missing file")
    }

    // MARK: - preloadTextures

    func test_preloadTextures_fromOverride_loadsOnlyImageRegions() async throws {
        let tempURL = try createTestImageFile(width: 100, height: 100)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal not available")
        }

        let provider = InMemoryTextureProvider()
        let service = BackgroundTextureService(
            textureProvider: provider,
            device: device,
            commandQueue: commandQueue,
            mediaLocator: ProjectStore(),
            mediaWriter: StubMediaWriter()
        )

        // Persist a test image to get a valid MediaRef
        let (mediaRef, persistedURL) = try await service.persistImage(from: tempURL)
        defer { try? FileManager.default.removeItem(at: persistedURL) }

        // Build override with one image region and one color region
        var override = ProjectBackgroundOverride.empty
        override.regions["region_img"] = RegionOverride(
            source: .image(ImageOverride(mediaRef: mediaRef, transform: .identity))
        )
        override.regions["region_color"] = RegionOverride(
            source: .solid(colorHex: "#FF0000")
        )

        let loadedKeys = await service.preloadTextures(from: override, presetId: "test_preset", assetRegistry: ProjectAssetRegistry())

        // Only the image region should have been loaded
        XCTAssertEqual(loadedKeys.count, 1, "Only image regions should be preloaded")
        XCTAssertTrue(loadedKeys.contains("bg/test_preset/region_img"))
        XCTAssertFalse(service.isLoaded("bg/test_preset/region_color"), "Color region should not produce a texture")
    }

    // MARK: - Editor Import-In-Flight Contract

    func test_editor_isImportInFlight_disablesDoneButton() {
        let editor = BackgroundEditorViewController(
            presetLibrary: BackgroundPresetLibrary.shared,
            templateBackground: nil,
            currentOverride: .empty
        )
        // Force view load to set up navigationItem
        _ = editor.view

        // Initially Done is enabled
        XCTAssertTrue(
            editor.navigationItem.rightBarButtonItem?.isEnabled ?? false,
            "Done should be enabled when no import is in flight"
        )

        // Set import in flight — Done must be disabled
        editor.isImportInFlight = true
        XCTAssertFalse(
            editor.navigationItem.rightBarButtonItem?.isEnabled ?? true,
            "Done should be disabled while import is in flight"
        )

        // Import completes — Done re-enabled
        editor.isImportInFlight = false
        XCTAssertTrue(
            editor.navigationItem.rightBarButtonItem?.isEnabled ?? false,
            "Done should be re-enabled after import completes"
        )
    }

    func test_editor_isImportInFlight_blocksNewImagePickerRequest() {
        // Set up an override with an image region so configureRegionTapped has a .image path
        var override = ProjectBackgroundOverride.empty
        override.regions["test_region"] = RegionOverride(
            source: .image(ImageOverride(
                mediaRef: MediaRef.file("media/Background/existing.jpg", mediaKind: .photo),
                transform: .identity
            ))
        )

        let editor = BackgroundEditorViewController(
            presetLibrary: BackgroundPresetLibrary.shared,
            templateBackground: nil,
            currentOverride: override
        )
        let spy = BackgroundEditorDelegateSpy()
        editor.delegate = spy
        _ = editor.view

        // With isImportInFlight = false, a configure tap on image region would request picker
        editor.isImportInFlight = false

        // Create a button with the region container's accessibilityIdentifier
        // to simulate configureRegionTapped
        let fakeButton = UIButton()
        let container = UIView()
        container.accessibilityIdentifier = "test_region"
        container.addSubview(fakeButton)

        // Trigger configureRegionTapped via selector
        editor.perform(Selector(("configureRegionTapped:")), with: fakeButton)
        XCTAssertEqual(spy.imagePickerRequestCount, 1,
                       "Image picker should be requested when import is NOT in flight")

        // Now set import in flight and try again
        editor.isImportInFlight = true
        editor.perform(Selector(("configureRegionTapped:")), with: fakeButton)
        XCTAssertEqual(spy.imagePickerRequestCount, 1,
                       "Image picker should NOT be requested when import IS in flight")
    }

    func test_editor_setImage_afterImportCompletes_updatesOverride() {
        let editor = BackgroundEditorViewController(
            presetLibrary: BackgroundPresetLibrary.shared,
            templateBackground: nil,
            currentOverride: .empty
        )
        _ = editor.view

        let mediaRef = MediaRef.file("media/Background/test.jpg", mediaKind: .photo)
        editor.setImage(for: "region_top", mediaRef: mediaRef)

        // Verify override was updated
        guard case .image(let imageOverride) = editor.override.regions["region_top"]?.source else {
            XCTFail("Region override should be image after setImage")
            return
        }
        XCTAssertEqual(imageOverride.mediaRef.storagePath, mediaRef.storagePath)
    }

    // MARK: - Helpers

    private func createTestImageFile(width: Int, height: Int) throws -> URL {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw NSError(domain: "Test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create context"])
        }

        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let cgImage = context.makeImage() else {
            throw NSError(domain: "Test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to make image"])
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_bg_\(UUID().uuidString).png")

        guard let dest = CGImageDestinationCreateWithURL(tempURL as CFURL, "public.png" as CFString, 1, nil) else {
            throw NSError(domain: "Test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create destination"])
        }

        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "Test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to finalize"])
        }

        return tempURL
    }
}

// MARK: - Test Helpers

/// Minimal ProjectMediaWriteGateway stub that delegates to ProjectStore() for background tests.
private struct StubMediaWriter: ProjectMediaWriteGateway {
    func saveBackgroundImage(from preparedFileURL: URL) async throws -> (MediaRef, URL) {
        try ProjectStore().saveBackgroundImage(from: preparedFileURL)
    }

    func saveUserMedia(from fileURL: URL, mediaKind: MediaKind, filename: String) async throws -> (MediaRef, URL) {
        try ProjectStore().saveUserMedia(from: fileURL, mediaKind: mediaKind, filename: filename)
    }

    func deleteMediaFile(_ mediaRef: MediaRef) async throws {
        try ProjectStore().deleteMediaFile(mediaRef)
    }

    func duplicateAssets(inDraft sourceDraft: ProjectDraft) async throws -> ProjectDraft { sourceDraft }
}

/// Spy delegate for BackgroundEditorViewController tests.
@MainActor
private final class BackgroundEditorDelegateSpy: BackgroundEditorDelegate {
    var imagePickerRequestCount = 0
    var lastImagePickerRegionId: String?
    var updateOverrideCount = 0
    var presetChangeCount = 0
    var dismissCount = 0

    func backgroundEditorDidUpdateOverride(_ override: ProjectBackgroundOverride) {
        updateOverrideCount += 1
    }

    func backgroundEditorDidRequestImagePicker(for regionId: String) {
        imagePickerRequestCount += 1
        lastImagePickerRegionId = regionId
    }

    func backgroundEditorDidChangePreset(oldPresetId: String, newPresetId: String) {
        presetChangeCount += 1
    }

    func backgroundEditorWillDismiss(override: ProjectBackgroundOverride, presetId: String) {
        dismissCount += 1
    }
}
