import XCTest
import Metal
import TVECore
@testable import AnimiApp

final class OverlayRenderResourceCacheTests: XCTestCase {

    private var device: MTLDevice!
    private let canvasSize = SizeD(width: 1080, height: 1920)
    private let pixelWidth = 1080

    override func setUpWithError() throws {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device not available")
        }
        device = dev
    }

    // MARK: - Helpers

    private func makeTextItem(
        text: String = "Hello",
        stableId: UUID = UUID(),
        zOrder: Int = 0
    ) -> ResolvedOverlayRenderItem {
        ResolvedOverlayRenderItem(
            stableId: stableId,
            kind: .text,
            content: .text(text: text, fontFamily: nil, fontSize: 32, colorHex: "#FFFFFF", boxWidth: 0.6),
            presentation: .default(centerX: 0.5, centerY: 0.5),
            zOrder: zOrder
        )
    }

    // MARK: - Cache Hit: same content → same texture

    func testCacheHit_sameContent_returnsSameTexture() {
        let cache = OverlayRenderResourceCache()
        let item = makeTextItem()

        let entry1 = cache.texture(for: item, device: device, canvasSize: canvasSize, canvasPixelWidth: pixelWidth)
        let entry2 = cache.texture(for: item, device: device, canvasSize: canvasSize, canvasPixelWidth: pixelWidth)

        XCTAssertNotNil(entry1)
        XCTAssertNotNil(entry2)
        // Same texture object on cache hit (pointer equality)
        XCTAssertTrue(entry1!.texture === entry2!.texture, "Cache hit should return the same MTLTexture instance")
    }

    // MARK: - Shared texture: different stableId, same content

    func testSharedTexture_differentStableId_sameContent_sharesCachedTexture() {
        let cache = OverlayRenderResourceCache()
        let itemA = makeTextItem(text: "Shared", stableId: UUID())
        let itemB = makeTextItem(text: "Shared", stableId: UUID())

        let entryA = cache.texture(for: itemA, device: device, canvasSize: canvasSize, canvasPixelWidth: pixelWidth)
        let entryB = cache.texture(for: itemB, device: device, canvasSize: canvasSize, canvasPixelWidth: pixelWidth)

        XCTAssertNotNil(entryA)
        XCTAssertNotNil(entryB)
        XCTAssertTrue(entryA!.texture === entryB!.texture,
                       "Two items with same content but different stableId should share one cached texture")
    }

    // MARK: - Cache miss: different content → different texture

    func testCacheMiss_differentContent_returnsDifferentTexture() {
        let cache = OverlayRenderResourceCache()
        let itemA = makeTextItem(text: "Alpha")
        let itemB = makeTextItem(text: "Beta")

        let entryA = cache.texture(for: itemA, device: device, canvasSize: canvasSize, canvasPixelWidth: pixelWidth)
        let entryB = cache.texture(for: itemB, device: device, canvasSize: canvasSize, canvasPixelWidth: pixelWidth)

        XCTAssertNotNil(entryA)
        XCTAssertNotNil(entryB)
        XCTAssertFalse(entryA!.texture === entryB!.texture,
                        "Different content should produce different textures")
    }

    // MARK: - Position change does NOT invalidate

    func testPositionChange_doesNotInvalidateCache() {
        let cache = OverlayRenderResourceCache()
        let id = UUID()
        let itemAtCenter = ResolvedOverlayRenderItem(
            stableId: id,
            kind: .text,
            content: .text(text: "Pos", fontFamily: nil, fontSize: 32, colorHex: "#FFFFFF", boxWidth: 0.6),
            presentation: .default(centerX: 0.5, centerY: 0.5),
            zOrder: 0
        )
        let itemMoved = ResolvedOverlayRenderItem(
            stableId: id,
            kind: .text,
            content: .text(text: "Pos", fontFamily: nil, fontSize: 32, colorHex: "#FFFFFF", boxWidth: 0.6),
            presentation: .default(centerX: 0.2, centerY: 0.8),
            zOrder: 0
        )

        let entry1 = cache.texture(for: itemAtCenter, device: device, canvasSize: canvasSize, canvasPixelWidth: pixelWidth)
        let entry2 = cache.texture(for: itemMoved, device: device, canvasSize: canvasSize, canvasPixelWidth: pixelWidth)

        XCTAssertNotNil(entry1)
        XCTAssertNotNil(entry2)
        XCTAssertTrue(entry1!.texture === entry2!.texture,
                       "Position change should not cause cache miss — key excludes position")
    }

    // MARK: - invalidateAll clears everything

    func testInvalidateAll_clearsCache() {
        let cache = OverlayRenderResourceCache()
        let item = makeTextItem()

        let entry1 = cache.texture(for: item, device: device, canvasSize: canvasSize, canvasPixelWidth: pixelWidth)
        XCTAssertNotNil(entry1)

        cache.invalidateAll()

        let entry2 = cache.texture(for: item, device: device, canvasSize: canvasSize, canvasPixelWidth: pixelWidth)
        XCTAssertNotNil(entry2)
        // After invalidateAll, must re-rasterize → different texture instance
        XCTAssertFalse(entry1!.texture === entry2!.texture,
                        "After invalidateAll, texture should be re-created (new instance)")
    }

    // MARK: - LRU eviction

    func testLRUEviction_evictsLeastRecentlyUsed() {
        let cache = OverlayRenderResourceCache()

        // Fill cache to capacity with unique items
        var textures: [String: MTLTexture] = [:]
        for i in 0..<OverlayRenderResourceCache.maxEntries {
            let item = makeTextItem(text: "Item_\(i)")
            let entry = cache.texture(for: item, device: device, canvasSize: canvasSize, canvasPixelWidth: pixelWidth)
            XCTAssertNotNil(entry)
            textures["Item_\(i)"] = entry?.texture
        }

        // Access item 0 to make it recently used
        let item0 = makeTextItem(text: "Item_0")
        _ = cache.texture(for: item0, device: device, canvasSize: canvasSize, canvasPixelWidth: pixelWidth)

        // Insert one more item → should evict item 1 (least recently used), not item 0
        let newItem = makeTextItem(text: "NewItem")
        let newEntry = cache.texture(for: newItem, device: device, canvasSize: canvasSize, canvasPixelWidth: pixelWidth)
        XCTAssertNotNil(newEntry)

        // item 0 should still be cached (was recently accessed)
        let item0Again = cache.texture(for: item0, device: device, canvasSize: canvasSize, canvasPixelWidth: pixelWidth)
        XCTAssertTrue(item0Again!.texture === textures["Item_0"]!,
                       "Item 0 was recently accessed and should survive eviction")

        // item 1 should have been evicted (LRU)
        let item1 = makeTextItem(text: "Item_1")
        let item1Again = cache.texture(for: item1, device: device, canvasSize: canvasSize, canvasPixelWidth: pixelWidth)
        XCTAssertFalse(item1Again!.texture === textures["Item_1"]!,
                        "Item 1 was LRU and should have been evicted — new texture expected")
    }

    // MARK: - purgeOnMemoryPressure

    func testPurgeOnMemoryPressure_clearsCache() {
        let cache = OverlayRenderResourceCache()
        let item = makeTextItem()

        let entry1 = cache.texture(for: item, device: device, canvasSize: canvasSize, canvasPixelWidth: pixelWidth)
        XCTAssertNotNil(entry1)

        cache.purgeOnMemoryPressure()

        let entry2 = cache.texture(for: item, device: device, canvasSize: canvasSize, canvasPixelWidth: pixelWidth)
        XCTAssertNotNil(entry2)
        XCTAssertFalse(entry1!.texture === entry2!.texture,
                        "After purge, texture should be re-created")
    }
}
