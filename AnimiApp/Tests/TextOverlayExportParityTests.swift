import XCTest
import TVECore
@testable import AnimiApp

/// Verifies preview and export resolve the SAME text-box state from the same
/// persisted payload: full geometry/style propagation and identical resolver
/// output (content descriptor + presentation). This is the preview/export
/// parity contract.
final class TextOverlayExportParityTests: XCTestCase {

    private func timelineWithText(_ payload: TextPayload, startUs: TimeUs = 1_000_000, durationUs: TimeUs = 2_000_000) -> (CanonicalTimeline, UUID) {
        var timeline = CanonicalTimeline.empty()
        let scenePid = UUID()
        timeline.payloads[scenePid] = .scene(ScenePayload(sceneTypeId: "s0"))
        timeline.tracks[0].items.append(TimelineItem(payloadId: scenePid, kind: .scene, startUs: nil, durationUs: 5_000_000))

        let textPid = UUID()
        timeline.payloads[textPid] = .text(payload)
        var overlay = Track(kind: .overlay)
        let item = TimelineItem(payloadId: textPid, kind: .text, startUs: startUs, durationUs: durationUs)
        overlay.items.append(item)
        timeline.tracks.append(overlay)
        return (timeline, item.id)
    }

    func testPayloadRoundTrip_preservesGeometryAndStyle() throws {
        var payload = TextPayload()
        payload.geometry = TextBoxGeometry(text: "Wrapped text", centerX: 0.3, centerY: 0.7, boxWidth: 0.42, rotation: 0.9)
        payload.style = TextStyle(fontFamily: "Helvetica", fontSize: 48, colorHex: "#00FF00")

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(TextPayload.self, from: data)
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.geometry.boxWidth, 0.42, accuracy: 1e-6)
        XCTAssertEqual(decoded.geometry.rotation, 0.9, accuracy: 1e-6)
        XCTAssertEqual(decoded.style.fontSize, 48, accuracy: 1e-6)
    }

    func testPreviewAndExport_resolveIdenticalTextBoxState() {
        var payload = TextPayload()
        payload.geometry = TextBoxGeometry(text: "Parity", centerX: 0.25, centerY: 0.8, boxWidth: 0.4, rotation: 0.5)
        payload.style = TextStyle(fontFamily: nil, fontSize: 36, colorHex: "#FF0000")

        let (timeline, _) = timelineWithText(payload)

        // Preview path: resolve from the live timeline.
        let previewItems = OverlayResolver.resolve(from: timeline, at: 2_000_000, stickerProvider: nil)
            .filter { $0.kind == .text }
        XCTAssertEqual(previewItems.count, 1)

        // Export path: build snapshot, then resolve from it.
        let snapshot = OverlayExportSnapshot.build(from: timeline, stickerProvider: nil)
        let exportItems = OverlayResolver.resolve(from: snapshot, at: 2_000_000)
            .filter { $0.kind == .text }
        XCTAssertEqual(exportItems.count, 1)

        let p = previewItems[0]
        let e = exportItems[0]

        // Content descriptor (cache key) must match exactly.
        XCTAssertEqual(p.content, e.content)
        guard case .text(let text, let family, let fontSize, let colorHex, let boxWidth) = p.content else {
            return XCTFail("Expected text content")
        }
        XCTAssertEqual(text, "Parity")
        XCTAssertNil(family)
        XCTAssertEqual(fontSize, 36, accuracy: 1e-6)
        XCTAssertEqual(colorHex, "#FF0000")
        XCTAssertEqual(boxWidth, 0.4, accuracy: 1e-6)

        // Presentation (center + rotation) must match.
        XCTAssertEqual(p.presentation.centerX, e.presentation.centerX, accuracy: 1e-6)
        XCTAssertEqual(p.presentation.centerY, e.presentation.centerY, accuracy: 1e-6)
        XCTAssertEqual(p.presentation.rotation, e.presentation.rotation, accuracy: 1e-6)
        XCTAssertEqual(p.presentation.rotation, 0.5, accuracy: 1e-6)
        XCTAssertEqual(p.presentation.scale, 1.0, accuracy: 1e-6, "Text size flows through layout, not presentation scale")
    }

    func testExportSnapshot_carriesBoxWidthAndRotation() {
        var payload = TextPayload()
        payload.geometry = TextBoxGeometry(text: "X", centerX: 0.5, centerY: 0.5, boxWidth: 0.33, rotation: 1.2)
        payload.style = TextStyle(fontSize: 22, colorHex: "#0000FF")
        let (timeline, _) = timelineWithText(payload)

        let snapshot = OverlayExportSnapshot.build(from: timeline, stickerProvider: nil)
        XCTAssertEqual(snapshot.textItems.count, 1)
        let item = snapshot.textItems[0]
        XCTAssertEqual(item.boxWidth, 0.33, accuracy: 1e-6)
        XCTAssertEqual(item.rotation, 1.2, accuracy: 1e-6)
        XCTAssertEqual(item.fontSize, 22, accuracy: 1e-6)
        XCTAssertEqual(item.colorHex, "#0000FF")
    }
}
