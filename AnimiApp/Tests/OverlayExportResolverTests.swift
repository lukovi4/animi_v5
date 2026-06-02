import XCTest
@testable import AnimiApp
@testable import TVECore

final class OverlayResolverSnapshotTests: XCTestCase {

    // MARK: - Build from CanonicalTimeline

    func testBuildFromCanonicalTimeline_text_flattensCorrectly() {
        var timeline = CanonicalTimeline.empty()
        let scenePayloadId = UUID()
        timeline.payloads[scenePayloadId] = .scene(ScenePayload(sceneTypeId: "s0"))
        timeline.tracks[0].items.append(
            TimelineItem(payloadId: scenePayloadId, kind: .scene, startUs: nil, durationUs: 5_000_000)
        )

        let textPid = UUID()
        timeline.payloads[textPid] = .text(TextPayload(
            text: "Hello",
            fontFamily: "Helvetica",
            fontSize: 48,
            colorHex: "#FF0000",
            centerX: 0.3,
            centerY: 0.7
        ))
        var overlayTrack = Track(kind: .overlay)
        overlayTrack.items.append(TimelineItem(
            payloadId: textPid, kind: .text, startUs: 1_000_000, durationUs: 2_000_000
        ))
        timeline.tracks.append(overlayTrack)

        let snapshot = OverlayExportSnapshot.build(from: timeline, stickerProvider: nil)

        XCTAssertEqual(snapshot.textItems.count, 1)
        let item = snapshot.textItems[0]
        XCTAssertEqual(item.startUs, 1_000_000)
        XCTAssertEqual(item.endUs, 3_000_000)
        XCTAssertEqual(item.text, "Hello")
        XCTAssertEqual(item.fontFamily, "Helvetica")
        XCTAssertEqual(item.fontSize, 48)
        XCTAssertEqual(item.colorHex, "#FF0000")
        XCTAssertEqual(item.centerX, 0.3)
        XCTAssertEqual(item.centerY, 0.7)
        XCTAssertTrue(snapshot.stickerItems.isEmpty)
    }

    func testBuildFromCanonicalTimeline_sticker_preResolvesURLs() {
        var timeline = CanonicalTimeline.empty()
        let scenePayloadId = UUID()
        timeline.payloads[scenePayloadId] = .scene(ScenePayload(sceneTypeId: "s0"))
        timeline.tracks[0].items.append(
            TimelineItem(payloadId: scenePayloadId, kind: .scene, startUs: nil, durationUs: 5_000_000)
        )

        let stickerPid = UUID()
        timeline.payloads[stickerPid] = .sticker(StickerPayload(stickerId: "star", centerX: 0.5, centerY: 0.5))
        var overlayTrack = Track(kind: .overlay)
        overlayTrack.items.append(TimelineItem(
            payloadId: stickerPid, kind: .sticker, startUs: 0, durationUs: 3_000_000
        ))
        timeline.tracks.append(overlayTrack)

        let provider = StubStickerProvider(urls: ["star": URL(fileURLWithPath: "/tmp/star.png")])
        let snapshot = OverlayExportSnapshot.build(from: timeline, stickerProvider: provider)

        XCTAssertEqual(snapshot.stickerItems.count, 1)
        XCTAssertEqual(snapshot.stickerItems[0].stickerId, "star")
        XCTAssertEqual(snapshot.stickerItems[0].imageURL, URL(fileURLWithPath: "/tmp/star.png"))
        XCTAssertEqual(snapshot.stickerItems[0].startUs, 0)
        XCTAssertEqual(snapshot.stickerItems[0].endUs, 3_000_000)
    }

    func testBuildFromCanonicalTimeline_stickerWithoutURL_filtered() {
        var timeline = CanonicalTimeline.empty()
        let scenePayloadId = UUID()
        timeline.payloads[scenePayloadId] = .scene(ScenePayload(sceneTypeId: "s0"))
        timeline.tracks[0].items.append(
            TimelineItem(payloadId: scenePayloadId, kind: .scene, startUs: nil, durationUs: 5_000_000)
        )

        let stickerPid = UUID()
        timeline.payloads[stickerPid] = .sticker(StickerPayload(stickerId: "missing", centerX: 0.5, centerY: 0.5))
        var overlayTrack = Track(kind: .overlay)
        overlayTrack.items.append(TimelineItem(
            payloadId: stickerPid, kind: .sticker, startUs: 0, durationUs: 3_000_000
        ))
        timeline.tracks.append(overlayTrack)

        // Provider returns nil for "missing"
        let provider = StubStickerProvider(urls: [:])
        let snapshot = OverlayExportSnapshot.build(from: timeline, stickerProvider: provider)

        XCTAssertTrue(snapshot.stickerItems.isEmpty, "Stickers without resolvable URLs should be filtered out")
    }

    // MARK: - Build from Tuples

    func testBuildFromTuples_matchesCanonicalTimelineBuild() {
        // Build via CanonicalTimeline
        var timeline = CanonicalTimeline.empty()
        let scenePayloadId = UUID()
        timeline.payloads[scenePayloadId] = .scene(ScenePayload(sceneTypeId: "s0"))
        timeline.tracks[0].items.append(
            TimelineItem(payloadId: scenePayloadId, kind: .scene, startUs: nil, durationUs: 5_000_000)
        )

        let textPid = UUID()
        let textPayload = TextPayload(text: "Match", fontSize: 24, colorHex: "#00FF00", centerX: 0.1, centerY: 0.9)
        timeline.payloads[textPid] = .text(textPayload)
        let textItem = TimelineItem(payloadId: textPid, kind: .text, startUs: 500_000, durationUs: 1_000_000)

        let stickerPid = UUID()
        let stickerPayload = StickerPayload(stickerId: "heart", centerX: 0.6, centerY: 0.4)
        timeline.payloads[stickerPid] = .sticker(stickerPayload)
        let stickerItem = TimelineItem(payloadId: stickerPid, kind: .sticker, startUs: 0, durationUs: 2_000_000)

        var overlayTrack = Track(kind: .overlay)
        overlayTrack.items.append(textItem)
        overlayTrack.items.append(stickerItem)
        timeline.tracks.append(overlayTrack)

        let stickerURL = URL(fileURLWithPath: "/tmp/heart.png")
        let provider = StubStickerProvider(urls: ["heart": stickerURL])
        let fromTimeline = OverlayExportSnapshot.build(from: timeline, stickerProvider: provider)

        // Build via tuples (same data)
        let fromTuples = OverlayExportSnapshot.build(
            textOverlayItems: [(item: textItem, payload: textPayload)],
            stickerOverlayItems: [(item: stickerItem, payload: stickerPayload, imageURL: stickerURL)]
        )

        XCTAssertEqual(fromTimeline.textItems.count, fromTuples.textItems.count)
        XCTAssertEqual(fromTimeline.stickerItems.count, fromTuples.stickerItems.count)

        XCTAssertEqual(fromTimeline.textItems[0].text, fromTuples.textItems[0].text)
        XCTAssertEqual(fromTimeline.textItems[0].startUs, fromTuples.textItems[0].startUs)
        XCTAssertEqual(fromTimeline.textItems[0].endUs, fromTuples.textItems[0].endUs)

        XCTAssertEqual(fromTimeline.stickerItems[0].stickerId, fromTuples.stickerItems[0].stickerId)
        XCTAssertEqual(fromTimeline.stickerItems[0].imageURL, fromTuples.stickerItems[0].imageURL)
    }

    // MARK: - Resolver

    func testResolveText_insideRange_returnsOverlay() {
        let snapshot = OverlayExportSnapshot(
            textItems: [
                .init(itemId: UUID(), startUs: 1_000_000, endUs: 3_000_000, text: "Hi",
                      fontFamily: nil, fontSize: 32, colorHex: "#FFFFFF", centerX: 0.5, centerY: 0.5,
                      boxWidth: 0.6, rotation: 0)
            ],
            stickerItems: []
        )

        let result = OverlayResolver.resolve(from: snapshot, at: 2_000_000)
        let textItems = result.filter { $0.kind == .text }
        XCTAssertEqual(textItems.count, 1)
        if case .text(let text, _, _, _, _) = textItems[0].content {
            XCTAssertEqual(text, "Hi")
        } else {
            XCTFail("Expected text content")
        }
    }

    func testResolveText_outsideRange_returnsEmpty() {
        let snapshot = OverlayExportSnapshot(
            textItems: [
                .init(itemId: UUID(), startUs: 1_000_000, endUs: 3_000_000, text: "Hi",
                      fontFamily: nil, fontSize: 32, colorHex: "#FFFFFF", centerX: 0.5, centerY: 0.5,
                      boxWidth: 0.6, rotation: 0)
            ],
            stickerItems: []
        )

        XCTAssertTrue(OverlayResolver.resolve(from: snapshot, at: 0).filter { $0.kind == .text }.isEmpty)
        XCTAssertTrue(OverlayResolver.resolve(from: snapshot, at: 4_000_000).filter { $0.kind == .text }.isEmpty)
    }

    func testResolveText_atEndBoundary_excluded() {
        let snapshot = OverlayExportSnapshot(
            textItems: [
                .init(itemId: UUID(), startUs: 1_000_000, endUs: 3_000_000, text: "Hi",
                      fontFamily: nil, fontSize: 32, colorHex: "#FFFFFF", centerX: 0.5, centerY: 0.5,
                      boxWidth: 0.6, rotation: 0)
            ],
            stickerItems: []
        )

        // At startUs: included
        XCTAssertEqual(OverlayResolver.resolve(from: snapshot, at: 1_000_000).filter { $0.kind == .text }.count, 1)
        // At endUs: excluded (half-open)
        XCTAssertTrue(OverlayResolver.resolve(from: snapshot, at: 3_000_000).filter { $0.kind == .text }.isEmpty)
    }

    func testResolveSticker_multipleOverlapping_allReturned() {
        let snapshot = OverlayExportSnapshot(
            textItems: [],
            stickerItems: [
                .init(itemId: UUID(), startUs: 0, endUs: 2_000_000, stickerId: "a",
                      imageURL: URL(fileURLWithPath: "/a.png"), centerX: 0.1, centerY: 0.1),
                .init(itemId: UUID(), startUs: 500_000, endUs: 3_000_000, stickerId: "b",
                      imageURL: URL(fileURLWithPath: "/b.png"), centerX: 0.9, centerY: 0.9),
                .init(itemId: UUID(), startUs: 5_000_000, endUs: 6_000_000, stickerId: "c",
                      imageURL: URL(fileURLWithPath: "/c.png"), centerX: 0.5, centerY: 0.5)
            ]
        )

        let result = OverlayResolver.resolve(from: snapshot, at: 1_000_000)
        let stickerItems = result.filter { $0.kind == .sticker }
        XCTAssertEqual(stickerItems.count, 2)
        let stickerIds: Set<String> = Set(stickerItems.compactMap { item in
            if case .sticker(let stickerId, _) = item.content { return stickerId }
            return nil
        })
        XCTAssertEqual(stickerIds, ["a", "b"])
    }
}

// MARK: - Test Stubs

private final class StubStickerProvider: StickerProviding {
    private let urls: [String: URL]
    init(urls: [String: URL]) { self.urls = urls }
    func loadFromBundle() throws {}
    func descriptor(for stickerId: String) -> StickerDescriptor? { nil }
    func resourceURL(for stickerId: String) -> URL? { urls[stickerId] }
    var allDescriptors: [StickerDescriptor] { [] }
    var count: Int { 0 }
}
