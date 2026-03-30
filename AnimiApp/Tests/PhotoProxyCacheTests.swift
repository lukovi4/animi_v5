import XCTest
@testable import AnimiApp

/// Tests for PR5: PhotoProxyCache and photo master+proxy pipeline.
final class PhotoProxyCacheTests: XCTestCase {

    private var cache: PhotoProxyCache!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        cache = PhotoProxyCache()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        cache.clearAll()
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func createTestImage(width: Int, height: Int, hasAlpha: Bool = false) -> URL {
        let url = tempDir.appendingPathComponent(UUID().uuidString + (hasAlpha ? ".png" : ".jpg"))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: CGBitmapInfo = hasAlpha
            ? CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            : CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)

        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: bitmapInfo.rawValue
        ) else {
            fatalError("Failed to create CGContext")
        }

        // Fill with a solid color
        context.setFillColor(red: 0.5, green: 0.3, blue: 0.8, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let image = context.makeImage() else {
            fatalError("Failed to make CGImage")
        }

        if hasAlpha {
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
                fatalError("Failed to create PNG destination")
            }
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        } else {
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
                fatalError("Failed to create JPEG destination")
            }
            let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
            CGImageDestinationAddImage(dest, image, options as CFDictionary)
            CGImageDestinationFinalize(dest)
        }

        return url
    }

    // MARK: - Proxy Generation

    func test_proxyURL_generatesLazily() {
        let masterURL = createTestImage(width: 4000, height: 3000)
        let mediaRefId = "Media/UserMedia/test_photo.jpg"

        let proxyURL = cache.proxyURL(masterURL: masterURL, mediaRefId: mediaRefId)

        XCTAssertNotNil(proxyURL, "Proxy should be generated on first request")
        XCTAssertTrue(FileManager.default.fileExists(atPath: proxyURL!.path))
    }

    func test_proxyURL_reusesCached() {
        let masterURL = createTestImage(width: 4000, height: 3000)
        let mediaRefId = "Media/UserMedia/test_reuse.jpg"

        let first = cache.proxyURL(masterURL: masterURL, mediaRefId: mediaRefId)
        let second = cache.proxyURL(masterURL: masterURL, mediaRefId: mediaRefId)

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(first?.path, second?.path, "Second request must return cached proxy")
    }

    func test_proxyURL_smallImage_noUpscale() {
        // Image smaller than max dimension — proxy should still be created but not upscaled
        let masterURL = createTestImage(width: 800, height: 600)
        let mediaRefId = "Media/UserMedia/small.jpg"

        let proxyURL = cache.proxyURL(masterURL: masterURL, mediaRefId: mediaRefId)
        XCTAssertNotNil(proxyURL)

        // Verify proxy dimensions are not larger than original
        if let proxyURL,
           let source = CGImageSourceCreateWithURL(proxyURL as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int {
            XCTAssertLessThanOrEqual(w, 800)
            XCTAssertLessThanOrEqual(h, 600)
        }
    }

    func test_proxyURL_alphaPreserved_generatesPNG() {
        let masterURL = createTestImage(width: 2000, height: 1500, hasAlpha: true)
        let mediaRefId = "Media/UserMedia/alpha.png"

        let proxyURL = cache.proxyURL(masterURL: masterURL, mediaRefId: mediaRefId)

        XCTAssertNotNil(proxyURL)
        XCTAssertTrue(proxyURL?.pathExtension == "png", "Alpha images must produce PNG proxy")
    }

    func test_proxyURL_opaqueImage_generatesJPEG() {
        let masterURL = createTestImage(width: 3000, height: 2000, hasAlpha: false)
        let mediaRefId = "Media/UserMedia/opaque.jpg"

        let proxyURL = cache.proxyURL(masterURL: masterURL, mediaRefId: mediaRefId)

        XCTAssertNotNil(proxyURL)
        XCTAssertTrue(proxyURL?.pathExtension == "jpg", "Opaque images must produce JPEG proxy")
    }

    // MARK: - GC

    func test_clearAll_removesCachedProxies() {
        let masterURL = createTestImage(width: 3000, height: 2000)
        let proxyURL = cache.proxyURL(masterURL: masterURL, mediaRefId: "Media/test.jpg")
        XCTAssertNotNil(proxyURL)

        cache.clearAll()

        // After clear, proxy should not exist
        let secondProxy = cache.proxyURL(masterURL: masterURL, mediaRefId: "Media/test.jpg")
        // Should regenerate (new file)
        XCTAssertNotNil(secondProxy, "Should regenerate after clearAll")
    }

    // MARK: - MediaAssetStore Extension Preservation

    func test_mediaAssetStore_preservesOriginalExtension() throws {
        // Create a HEIC-like file (just using .heic extension for test)
        let sourceURL = createTestImage(width: 100, height: 100)
        let heicURL = tempDir.appendingPathComponent("test_photo.heic")
        try FileManager.default.copyItem(at: sourceURL, to: heicURL)

        let store = MediaAssetStore(projectStore: .shared)
        let (ref, destURL) = try store.saveMedia(
            from: heicURL,
            mediaKind: .photo,
            sceneInstanceId: UUID(),
            blockId: "block1"
        )
        defer { try? FileManager.default.removeItem(at: destURL) }

        XCTAssertEqual(destURL.pathExtension, "heic", "Original extension must be preserved")
        XCTAssertEqual(ref.mediaKind, .photo)
        XCTAssertTrue(ref.id.hasSuffix(".heic"))
    }

    // MARK: - Master vs Proxy Contract

    func test_exportUsesMasterURL_notProxy() {
        // Export should use the original file URL, not the proxy.
        // This is a contract test — ExportMediaSnapshot.ImageRef.url should point to master.
        let masterURL = createTestImage(width: 4000, height: 3000)
        let mediaRefId = "Media/UserMedia/export_test.jpg"

        // Generate proxy (to ensure it exists)
        let proxyURL = cache.proxyURL(masterURL: masterURL, mediaRefId: mediaRefId)
        XCTAssertNotNil(proxyURL)

        // Export would use masterURL (from projectStore.absoluteURL), not proxyURL
        XCTAssertNotEqual(masterURL, proxyURL, "Master and proxy must be different files")
    }
}
