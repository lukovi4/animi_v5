import XCTest
@testable import AnimiApp

/// Unit tests for PR1: Canonical Timeline v4 migration.
/// Tests cover:
/// - v3 → v4 migration
/// - Min duration normalization (0.1s = 100_000 µs)
/// - Codable roundtrip for TimelinePayload
/// - Scene duration sum preservation
final class CanonicalTimelineMigrationTests: XCTestCase {

    // MARK: - Migration Tests

    /// Test: v3 project with scenes migrates to v4 canonical timeline.
    func testMigration_v3ScenesConvertToCanonicalTimeline() {
        // Given: v3 project with 3 scenes
        var draft = ProjectDraft(
            schemaVersion: 3,
            templateId: "test-template",
            scenes: [
                SceneDraft(id: UUID(), durationUs: 2_000_000),  // 2s
                SceneDraft(id: UUID(), durationUs: 3_000_000),  // 3s
                SceneDraft(id: UUID(), durationUs: 1_000_000),  // 1s
            ]
        )
        let originalSceneIds = draft.scenes!.map { $0.id }
        let originalDuration = draft.scenes!.reduce(0) { $0 + $1.durationUs }

        // When: migrate to v4
        let result = draft.migrateToCanonicalTimelineIfNeeded(templateDefaultUs: 10_000_000)

        // Then: migration performed
        XCTAssertTrue(result.didMigrate)
        XCTAssertEqual(result.scenesExtended, 0)
        XCTAssertEqual(result.durationIncreaseUs, 0)

        // Then: canonical timeline exists
        XCTAssertNotNil(draft.canonicalTimeline)
        XCTAssertNil(draft.scenes, "Legacy scenes should be nil after migration")

        // Then: schema version updated
        XCTAssertEqual(draft.schemaVersion, 4)

        // Then: scene items preserve IDs and durations
        let canonical = draft.canonicalTimeline!
        XCTAssertEqual(canonical.sceneItems.count, 3)

        for (index, item) in canonical.sceneItems.enumerated() {
            XCTAssertEqual(item.id, originalSceneIds[index], "Scene item ID should match original SceneDraft ID")
            XCTAssertEqual(item.kind, .scene)
            XCTAssertNil(item.startUs, "Scene sequence items should have nil startUs (derived)")
        }

        // Then: total duration preserved
        XCTAssertEqual(canonical.totalDurationUs, originalDuration)
    }

    /// Test: Scene shorter than 0.1s is extended during migration.
    func testMigration_shortSceneExtendedToMinDuration() {
        // Given: v3 project with short scene (50ms < 100ms min)
        var draft = ProjectDraft(
            schemaVersion: 3,
            templateId: "test-template",
            scenes: [
                SceneDraft(id: UUID(), durationUs: 50_000),     // 50ms (too short)
                SceneDraft(id: UUID(), durationUs: 2_000_000),  // 2s
            ]
        )
        let originalDuration = draft.scenes!.reduce(0) { $0 + $1.durationUs }

        // When: migrate to v4
        let result = draft.migrateToCanonicalTimelineIfNeeded(templateDefaultUs: 10_000_000)

        // Then: migration reports extension
        XCTAssertTrue(result.didMigrate)
        XCTAssertEqual(result.scenesExtended, 1)
        XCTAssertEqual(result.durationIncreaseUs, 50_000) // 100_000 - 50_000

        // Then: scene extended to minimum
        let canonical = draft.canonicalTimeline!
        XCTAssertEqual(canonical.sceneItems[0].durationUs, ProjectDraft.minSceneDurationUs)

        // Then: total duration increased
        XCTAssertEqual(canonical.totalDurationUs, originalDuration + 50_000)
    }

    /// Test: Already v4 project is not re-migrated.
    func testMigration_v4ProjectNotReMigrated() {
        // Given: v4 project with canonical timeline
        let canonical = CanonicalTimeline.empty()
        var draft = ProjectDraft(
            schemaVersion: 4,
            templateId: "test-template",
            canonicalTimeline: canonical
        )

        // When: attempt migration
        let result = draft.migrateToCanonicalTimelineIfNeeded(templateDefaultUs: 10_000_000)

        // Then: no migration
        XCTAssertFalse(result.didMigrate)
        XCTAssertEqual(result.scenesExtended, 0)
    }

    /// Test: Project without scenes creates default single scene.
    func testMigration_noScenesCreatesDefault() {
        // Given: v3 project without scenes (legacy projectDurationUs)
        var draft = ProjectDraft(
            schemaVersion: 3,
            templateId: "test-template",
            projectDurationUs: 5_000_000  // 5s
        )

        // When: migrate
        let result = draft.migrateToCanonicalTimelineIfNeeded(templateDefaultUs: 10_000_000)

        // Then: single scene created with projectDurationUs
        XCTAssertTrue(result.didMigrate)
        let canonical = draft.canonicalTimeline!
        XCTAssertEqual(canonical.sceneItems.count, 1)
        XCTAssertEqual(canonical.totalDurationUs, 5_000_000)
    }

    // MARK: - Codable Tests

    /// Test: TimelinePayload encodes with type discriminator.
    func testTimelinePayload_encodesWithTypeDiscriminator() throws {
        // Given
        let payload = TimelinePayload.scene(ScenePayload())

        // When
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        let json = String(data: data, encoding: .utf8)!

        // Then: contains type discriminator
        XCTAssertTrue(json.contains("\"type\":\"scene\""))
        XCTAssertTrue(json.contains("\"payload\""))
    }

    /// Test: TimelinePayload roundtrip for all types.
    func testTimelinePayload_codableRoundtrip() throws {
        let payloads: [TimelinePayload] = [
            .scene(ScenePayload()),
            .audio(AudioPayload(volume: 0.8)),
            .sticker(StickerPayload(stickerId: "test-sticker")),
            .text(TextPayload(text: "Hello", fontFamily: "Arial", fontSize: 24, colorHex: "#FF0000"))
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for original in payloads {
            // When: encode and decode
            let data = try encoder.encode(original)
            let decoded = try decoder.decode(TimelinePayload.self, from: data)

            // Then: roundtrip preserves value
            XCTAssertEqual(decoded, original)
        }
    }

    /// Test: CanonicalTimeline full roundtrip.
    func testCanonicalTimeline_codableRoundtrip() throws {
        // Given: timeline with scene track
        let payloadId = UUID()
        var timeline = CanonicalTimeline.empty()
        timeline.payloads[payloadId] = .scene(ScenePayload())
        timeline.tracks[0].items.append(
            TimelineItem(payloadId: payloadId, kind: .scene, durationUs: 3_000_000)
        )

        // When: encode and decode
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(timeline)
        let decoded = try decoder.decode(CanonicalTimeline.self, from: data)

        // Then: roundtrip preserves structure
        XCTAssertEqual(decoded.tracks.count, timeline.tracks.count)
        XCTAssertEqual(decoded.payloads.count, timeline.payloads.count)
        XCTAssertEqual(decoded.totalDurationUs, timeline.totalDurationUs)
    }

    // MARK: - SceneDraft Adapter Tests

    /// Test: toSceneDrafts() correctly converts TimelineItems.
    func testToSceneDrafts_convertsCorrectly() {
        // Given
        let sceneId1 = UUID()
        let sceneId2 = UUID()
        let payloadId1 = UUID()
        let payloadId2 = UUID()

        var timeline = CanonicalTimeline.empty()
        timeline.payloads[payloadId1] = .scene(ScenePayload())
        timeline.payloads[payloadId2] = .scene(ScenePayload())
        timeline.tracks[0].items = [
            TimelineItem(id: sceneId1, payloadId: payloadId1, kind: .scene, durationUs: 2_000_000),
            TimelineItem(id: sceneId2, payloadId: payloadId2, kind: .scene, durationUs: 3_000_000)
        ]

        // When
        let sceneDrafts = timeline.toSceneDrafts()

        // Then
        XCTAssertEqual(sceneDrafts.count, 2)
        XCTAssertEqual(sceneDrafts[0].id, sceneId1)
        XCTAssertEqual(sceneDrafts[0].durationUs, 2_000_000)
        XCTAssertEqual(sceneDrafts[1].id, sceneId2)
        XCTAssertEqual(sceneDrafts[1].durationUs, 3_000_000)
    }

    /// Test: updateSceneDuration() modifies correct item.
    func testUpdateSceneDuration_modifiesCorrectItem() {
        // Given
        let sceneId = UUID()
        let payloadId = UUID()

        var timeline = CanonicalTimeline.empty()
        timeline.payloads[payloadId] = .scene(ScenePayload())
        timeline.tracks[0].items = [
            TimelineItem(id: sceneId, payloadId: payloadId, kind: .scene, durationUs: 2_000_000)
        ]

        // When
        let result = timeline.updateSceneDuration(sceneId: sceneId, newDurationUs: 5_000_000)

        // Then
        XCTAssertTrue(result)
        XCTAssertEqual(timeline.sceneItems[0].durationUs, 5_000_000)
    }

    // MARK: - Computed StartUs Tests

    /// Test: computedStartUs returns cumulative sum.
    func testComputedStartUs_returnsCumulativeSum() {
        // Given: 3 scenes with different durations
        var timeline = CanonicalTimeline.empty()
        let durations: [TimeUs] = [2_000_000, 3_000_000, 1_500_000]

        for duration in durations {
            let payloadId = UUID()
            timeline.payloads[payloadId] = .scene(ScenePayload())
            timeline.tracks[0].items.append(
                TimelineItem(payloadId: payloadId, kind: .scene, durationUs: duration)
            )
        }

        // Then
        XCTAssertEqual(timeline.computedStartUs(forSceneAt: 0), 0)
        XCTAssertEqual(timeline.computedStartUs(forSceneAt: 1), 2_000_000)
        XCTAssertEqual(timeline.computedStartUs(forSceneAt: 2), 5_000_000) // 2M + 3M
    }

    // MARK: - Track Invariant Tests

    /// Test: sceneSequence track is always at index 0.
    func testSceneSequenceTrack_alwaysAtIndex0() {
        let timeline = CanonicalTimeline.empty()

        XCTAssertEqual(timeline.tracks.count, 1)
        XCTAssertEqual(timeline.tracks[0].kind, .sceneSequence)
    }

    /// Test: TrackKind allows correct ItemKinds.
    func testTrackKind_allowsCorrectItemKinds() {
        XCTAssertTrue(TrackKind.sceneSequence.allows(.scene))
        XCTAssertFalse(TrackKind.sceneSequence.allows(.audioClip))

        XCTAssertTrue(TrackKind.audio.allows(.audioClip))
        XCTAssertFalse(TrackKind.audio.allows(.scene))

        XCTAssertTrue(TrackKind.overlay.allows(.sticker))
        XCTAssertTrue(TrackKind.overlay.allows(.text))
        XCTAssertFalse(TrackKind.overlay.allows(.scene))
    }
}
