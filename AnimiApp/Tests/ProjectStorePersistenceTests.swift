import XCTest
import TVECore
@testable import AnimiApp

/// Disk-roundtrip tests for ProjectStore + ProjectDraft (v6 schema).
/// Validates current-schema persistence contract with no migrations.
final class ProjectStorePersistenceTests: XCTestCase {

    // MARK: - Helper

    /// Builds a maximally-populated ProjectDraft exercising all payload discriminators,
    /// background region types, scene instance state fields, and transition slots.
    private func makeFullDraft(templateId: String, projectId: UUID) -> ProjectDraft {
        // Fixed whole-second dates (ISO8601 safe)
        let created = Date(timeIntervalSince1970: 1705312800) // 2024-01-15T12:00:00Z
        let updated = Date(timeIntervalSince1970: 1705316400) // 2024-01-15T13:00:00Z

        // --- Timeline ---
        var timeline = CanonicalTimeline.empty()
        var payloads: [UUID: TimelinePayload] = [:]

        // Scene sequence track (3 scenes)
        let scenePayloadIds = (0..<3).map { _ in UUID() }
        for (i, pid) in scenePayloadIds.enumerated() {
            payloads[pid] = .scene(ScenePayload(sceneTypeId: "scene_type_\(i)"))
            let item = TimelineItem(
                payloadId: pid,
                kind: .scene,
                startUs: nil,
                durationUs: 2_000_000
            )
            timeline.tracks[0].items.append(item)
        }

        // Audio track (1 clip)
        let audioPayloadId = UUID()
        payloads[audioPayloadId] = .audio(AudioPayload(
            assetRef: .bundled(id: "track_01"),
            volume: 0.8
        ))
        var audioTrack = Track(kind: .audio)
        audioTrack.items.append(TimelineItem(
            payloadId: audioPayloadId,
            kind: .audioClip,
            startUs: 0,
            durationUs: 6_000_000
        ))
        timeline.tracks.append(audioTrack)

        // Overlay track (1 sticker + 1 text)
        let stickerPayloadId = UUID()
        payloads[stickerPayloadId] = .sticker(StickerPayload(stickerId: "emoji_heart"))
        let textPayloadId = UUID()
        payloads[textPayloadId] = .text(TextPayload(
            text: "Hello TT-11",
            fontFamily: "Helvetica",
            fontSize: 32,
            colorHex: "#FF00FF"
        ))
        var overlayTrack = Track(kind: .overlay)
        overlayTrack.items.append(TimelineItem(
            payloadId: stickerPayloadId,
            kind: .sticker,
            startUs: 500_000,
            durationUs: 1_000_000
        ))
        overlayTrack.items.append(TimelineItem(
            payloadId: textPayloadId,
            kind: .text,
            startUs: 1_000_000,
            durationUs: 2_000_000
        ))
        timeline.tracks.append(overlayTrack)

        timeline.payloads = payloads

        // Boundary transitions (2 distinct types)
        let sceneItems = timeline.sceneItems
        let key01 = SceneBoundaryKey(sceneItems[0].id, sceneItems[1].id)
        timeline.boundaryTransitions[key01] = SceneTransition(
            type: .fade,
            durationFrames: 14,
            easingPreset: .linear
        )
        let key12 = SceneBoundaryKey(sceneItems[1].id, sceneItems[2].id)
        timeline.boundaryTransitions[key12] = SceneTransition(
            type: .push(direction: .left),
            durationFrames: 10,
            easingPreset: .easeInOut
        )

        // Intro + outro
        timeline.introTransition = SceneTransition(
            type: .dipToBlack,
            durationFrames: 15,
            easingPreset: .easeInOut
        )
        timeline.outroTransition = SceneTransition(
            type: .fade,
            durationFrames: 12,
            easingPreset: .linear
        )

        // --- Scene instance states ---
        var states: [UUID: SceneState] = [:]
        for (i, item) in sceneItems.enumerated() {
            var s = SceneState.empty
            s.variantOverrides = ["block_\(i)": "variant_\(i)"]
            s.userTransforms = ["block_\(i)": Matrix2D(
                a: 1.2, b: 0.1, c: -0.1, d: 1.2,
                tx: Double(i) * 10, ty: Double(i) * 20
            )]
            s.layerToggles = ["block_\(i)": ["visible": true, "shadow": false]]
            s.mediaAssignments = ["block_\(i)": MediaRef.file("Media/UserMedia/img_\(i).jpg")]
            s.userMediaPresent = ["block_\(i)": i % 2 == 0]
            states[item.id] = s
        }

        // --- Background ---
        let background = ProjectBackgroundOverride(
            selectedPresetId: "sunset_01",
            regions: [
                "gradient_region": RegionOverride(source: .gradient(GradientOverride(
                    stops: [
                        GradientStopOverride(t: 0.0, colorHex: "#FF0000"),
                        GradientStopOverride(t: 1.0, colorHex: "#0000FF")
                    ],
                    p0: Point2(x: 0.0, y: 0.0),
                    p1: Point2(x: 1.0, y: 1.0)
                ))),
                "image_region": RegionOverride(source: .image(ImageOverride(
                    mediaRef: MediaRef.file("Media/Background/bg_img.jpg"),
                    transform: BgImageTransformOverride(
                        pan: Point2(x: 0.1, y: 0.2),
                        zoom: 1.5,
                        rotationRadians: 0.3,
                        flipX: true,
                        flipY: false,
                        fitMode: "fill"
                    )
                )))
            ]
        )

        return ProjectDraft(
            schemaVersion: ProjectDraft.currentSchemaVersion,
            id: projectId,
            templateId: templateId,
            name: "TT-11 Full Draft",
            createdAt: created,
            updatedAt: updated,
            background: background,
            canonicalTimeline: timeline,
            sceneInstanceStates: states
        )
    }

    // MARK: - Tests

    /// Full draft save → load roundtrip through ProjectStore.
    func testProjectStore_saveLoad_roundtrip_preservesCurrentSchemaDraft() throws {
        let templateId = "tt11-\(UUID())"
        let store = ProjectStore()
        defer { try? store.deleteProject(templateId: templateId) }

        let projectId = try store.createOrLoadProjectId(for: templateId)
        let draft = makeFullDraft(templateId: templateId, projectId: projectId)

        // Save
        try store.saveProjectDraft(draft)

        // Load
        let loaded = try store.loadProjectDraft(projectId: projectId, templateId: templateId)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded, draft)

        // Spot-checks for key fields
        let l = try XCTUnwrap(loaded)
        XCTAssertEqual(l.schemaVersion, ProjectDraft.currentSchemaVersion)
        XCTAssertEqual(l.name, "TT-11 Full Draft")
        XCTAssertEqual(l.canonicalTimeline.tracks.count, 3)
        XCTAssertEqual(l.canonicalTimeline.boundaryTransitions.count, 2)
        XCTAssertNotNil(l.canonicalTimeline.introTransition)
        XCTAssertNotNil(l.canonicalTimeline.outroTransition)
        XCTAssertEqual(l.sceneInstanceStates.count, 3)
        XCTAssertEqual(l.background.selectedPresetId, "sunset_01")
        XCTAssertEqual(l.background.regions.count, 2)

        // Verify all 4 payload discriminators present
        let payloadTypes = Set(l.canonicalTimeline.payloads.values.map { payload -> String in
            switch payload {
            case .scene: return "scene"
            case .audio: return "audio"
            case .sticker: return "sticker"
            case .text: return "text"
            }
        })
        XCTAssertEqual(payloadTypes, ["scene", "audio", "sticker", "text"])
    }

    /// Schema version mismatch → loadProjectDraft returns nil.
    func testLoadProjectDraft_schemaMismatch_returnsNil() throws {
        let templateId = "tt11-\(UUID())"
        let store = ProjectStore()
        defer { try? store.deleteProject(templateId: templateId) }

        let projectId = try store.createOrLoadProjectId(for: templateId)

        // Write JSON with schema version 999 directly to disk
        let url = try store.projectsDirectoryURL()
            .appendingPathComponent("\(projectId.uuidString).json")
        try store.ensureDirectoriesExist()

        var mismatchDraft = ProjectDraft.create(for: templateId, projectId: projectId)
        mismatchDraft.schemaVersion = 999
        // Use same encoder config as ProjectStore
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(mismatchDraft)
        try data.write(to: url, options: .atomic)

        // Load should return nil due to schema mismatch
        let loaded = try store.loadProjectDraft(projectId: projectId, templateId: templateId)
        XCTAssertNil(loaded)
    }

    /// Schema mismatch on disk → createOrLoadProjectDraft returns fresh v6 draft.
    func testCreateOrLoadProjectDraft_schemaMismatch_createsNewEmptyCurrentSchemaDraft() throws {
        let templateId = "tt11-\(UUID())"
        let store = ProjectStore()
        defer { try? store.deleteProject(templateId: templateId) }

        let projectId = try store.createOrLoadProjectId(for: templateId)

        // Write schema-999 file to disk
        let url = try store.projectsDirectoryURL()
            .appendingPathComponent("\(projectId.uuidString).json")
        try store.ensureDirectoriesExist()

        var mismatchDraft = ProjectDraft.create(for: templateId, projectId: projectId)
        mismatchDraft.schemaVersion = 999
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(mismatchDraft)
        try data.write(to: url, options: .atomic)

        // createOrLoadProjectDraft should create a new v6 draft reusing the same projectId
        let result = try store.createOrLoadProjectDraft(for: templateId)
        XCTAssertEqual(result.id, projectId)
        XCTAssertEqual(result.schemaVersion, ProjectDraft.currentSchemaVersion)
        XCTAssertEqual(result.templateId, templateId)
        XCTAssertTrue(result.canonicalTimeline.sceneItems.isEmpty)
    }

    /// Empty draft roundtrips correctly.
    func testProjectStore_saveLoad_emptyDraft_roundtrip() throws {
        let templateId = "tt11-\(UUID())"
        let store = ProjectStore()
        defer { try? store.deleteProject(templateId: templateId) }

        let projectId = try store.createOrLoadProjectId(for: templateId)
        // Use whole-second dates to survive ISO8601 roundtrip
        let now = Date(timeIntervalSince1970: 1705312800)
        let draft = ProjectDraft(
            id: projectId,
            templateId: templateId,
            createdAt: now,
            updatedAt: now
        )

        try store.saveProjectDraft(draft)

        let loaded = try store.loadProjectDraft(projectId: projectId, templateId: templateId)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded, draft)
    }
}
