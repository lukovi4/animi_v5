import XCTest
@testable import AnimiApp

/// Tests for PersistedVideoSelection persistence model.
final class PersistedVideoSelectionTests: XCTestCase {

    // MARK: - Codable Round-Trip

    func test_roundTrip_preservesAllFields() throws {
        let original = PersistedVideoSelection(
            trimStart: 1.5,
            trimEnd: 10.0,
            offset: 0.25,
            isMuted: true,
            volume: 0.7
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PersistedVideoSelection.self, from: data)

        XCTAssertEqual(decoded.trimStart, 1.5)
        XCTAssertEqual(decoded.trimEnd, 10.0)
        XCTAssertEqual(decoded.offset, 0.25)
        XCTAssertEqual(decoded.isMuted, true)
        XCTAssertEqual(decoded.volume, 0.7, accuracy: 0.001)
    }

    func test_roundTrip_defaultValues() throws {
        let original = PersistedVideoSelection(trimEnd: 5.0)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PersistedVideoSelection.self, from: data)

        XCTAssertEqual(decoded.trimStart, 0)
        XCTAssertEqual(decoded.trimEnd, 5.0)
        XCTAssertEqual(decoded.offset, 0)
        XCTAssertEqual(decoded.isMuted, false)
        XCTAssertEqual(decoded.volume, 1.0, accuracy: 0.001)
    }

    // MARK: - Factory from VideoSelection

    func test_initFromVideoSelection_extractsParams() {
        let vs = VideoSelection(
            url: URL(fileURLWithPath: "/tmp/video.mp4"),
            trimStart: 2.0,
            trimEnd: 8.0,
            offset: 1.0,
            isMuted: true,
            volume: 0.5
        )

        let pvs = PersistedVideoSelection(from: vs)

        XCTAssertEqual(pvs.trimStart, 2.0)
        XCTAssertEqual(pvs.trimEnd, 8.0)
        XCTAssertEqual(pvs.offset, 1.0)
        XCTAssertEqual(pvs.isMuted, true)
        XCTAssertEqual(pvs.volume, 0.5, accuracy: 0.001)
    }

    // MARK: - Assembly to VideoSelection

    func test_toVideoSelection_assemblesWithURL() {
        let pvs = PersistedVideoSelection(
            trimStart: 1.0,
            trimEnd: 9.0,
            offset: 0.5,
            isMuted: false,
            volume: 0.8
        )

        let url = URL(fileURLWithPath: "/tmp/test.mp4")
        let vs = pvs.toVideoSelection(url: url)

        XCTAssertEqual(vs.url, url)
        XCTAssertEqual(vs.trimStart, 1.0)
        XCTAssertEqual(vs.trimEnd, 9.0)
        XCTAssertEqual(vs.offset, 0.5)
        XCTAssertEqual(vs.isMuted, false)
        XCTAssertEqual(vs.volume, 0.8, accuracy: 0.001)
        XCTAssertTrue(vs.isValid)
    }

    // MARK: - SceneState Integration

    func test_sceneState_withVideoSelections_encodesDecodes() throws {
        var state = SceneState.empty
        state.videoSelections = [
            "block1": PersistedVideoSelection(trimStart: 0, trimEnd: 5.0),
            "block2": PersistedVideoSelection(trimStart: 1.0, trimEnd: 10.0, isMuted: true)
        ]

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(SceneState.self, from: data)

        XCTAssertEqual(decoded.videoSelections?.count, 2)
        XCTAssertEqual(decoded.videoSelections?["block1"]?.trimEnd, 5.0)
        XCTAssertEqual(decoded.videoSelections?["block2"]?.isMuted, true)
    }

    func test_sceneState_backwardCompat_nilVideoSelections() throws {
        // Old JSON without videoSelections field
        let json = """
        {"variantOverrides":{},"userTransforms":{},"layerToggles":{}}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SceneState.self, from: data)

        XCTAssertNil(decoded.videoSelections)
    }
}
