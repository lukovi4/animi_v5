import XCTest
import TVECore
@testable import AnimiApp

/// Disk-roundtrip tests for ProjectStore + SavedProjectRecord + ActiveDraftSlot (v6 schema).
/// Validates current-schema persistence contract with SavedProjects API.
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

    /// Full draft save → load roundtrip through SavedProjectRecord.
    func testSavedProjectRecord_roundtrip_preservesCurrentSchemaDraft() throws {
        let templateId = "tt11-\(UUID())"
        let store = ProjectStore()
        let projectId = UUID()
        let draft = makeFullDraft(templateId: templateId, projectId: projectId)

        // Materialize via ActiveDraftSlot
        var slot = ActiveDraftSlot(
            entryContext: .newFromTemplate(templateId: templateId),
            sourceTemplateId: templateId,
            linkedSavedProjectId: nil,
            draft: draft
        )
        try store.materializeSavedProject(from: &slot)

        // Cleanup
        defer { try? store.deleteSavedProject(projectId: projectId) }

        // Load
        let loaded = store.loadSavedProject(projectId: projectId)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.draft, draft)
        XCTAssertEqual(loaded?.sourceTemplateId, templateId)

        // Identity invariant
        XCTAssertEqual(loaded?.id, draft.id)
        XCTAssertEqual(slot.linkedSavedProjectId, projectId)

        // Spot-checks for key fields
        let l = try XCTUnwrap(loaded)
        XCTAssertEqual(l.draft.schemaVersion, ProjectDraft.currentSchemaVersion)
        XCTAssertEqual(l.draft.name, "TT-11 Full Draft")
        XCTAssertEqual(l.draft.canonicalTimeline.tracks.count, 3)
        XCTAssertEqual(l.draft.canonicalTimeline.boundaryTransitions.count, 2)
        XCTAssertNotNil(l.draft.canonicalTimeline.introTransition)
        XCTAssertNotNil(l.draft.canonicalTimeline.outroTransition)
        XCTAssertEqual(l.draft.sceneInstanceStates.count, 3)
        XCTAssertEqual(l.draft.background.selectedPresetId, "sunset_01")
        XCTAssertEqual(l.draft.background.regions.count, 2)

        // Verify all 4 payload discriminators present
        let payloadTypes = Set(l.draft.canonicalTimeline.payloads.values.map { payload -> String in
            switch payload {
            case .scene: return "scene"
            case .audio: return "audio"
            case .sticker: return "sticker"
            case .text: return "text"
            }
        })
        XCTAssertEqual(payloadTypes, ["scene", "audio", "sticker", "text"])
    }

    /// ActiveDraftSlot roundtrip.
    func testActiveDraftSlot_roundtrip() throws {
        let templateId = "tt11-\(UUID())"
        let store = ProjectStore()
        let projectId = UUID()
        let draft = makeFullDraft(templateId: templateId, projectId: projectId)

        let slot = ActiveDraftSlot(
            entryContext: .newFromTemplate(templateId: templateId),
            sourceTemplateId: templateId,
            linkedSavedProjectId: nil,
            draft: draft
        )

        try store.saveActiveDraft(slot)
        defer { try? store.deleteActiveDraft() }

        XCTAssertTrue(store.hasActiveDraft())

        let loaded = store.loadActiveDraft()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.draft, draft)
        XCTAssertEqual(loaded?.sourceTemplateId, templateId)
        XCTAssertEqual(loaded?.entryContext, .newFromTemplate(templateId: templateId))
        XCTAssertNil(loaded?.linkedSavedProjectId)
    }

    /// Multiple saved projects with same sourceTemplateId.
    func testMultipleSavedProjects_sameTemplate() throws {
        let templateId = "tt11-\(UUID())"
        let store = ProjectStore()

        let id1 = UUID()
        let id2 = UUID()
        let draft1 = ProjectDraft.create(for: templateId, projectId: id1)
        let draft2 = ProjectDraft.create(for: templateId, projectId: id2)

        var slot1 = ActiveDraftSlot(
            entryContext: .newFromTemplate(templateId: templateId),
            sourceTemplateId: templateId,
            linkedSavedProjectId: nil,
            draft: draft1
        )
        try store.materializeSavedProject(from: &slot1)

        var slot2 = ActiveDraftSlot(
            entryContext: .newFromTemplate(templateId: templateId),
            sourceTemplateId: templateId,
            linkedSavedProjectId: nil,
            draft: draft2
        )
        try store.materializeSavedProject(from: &slot2)

        defer {
            try? store.deleteSavedProject(projectId: id1)
            try? store.deleteSavedProject(projectId: id2)
        }

        let entries = store.allSavedProjectEntries()
        let projectIds = Set(entries.map(\.projectId))
        XCTAssertTrue(projectIds.contains(id1))
        XCTAssertTrue(projectIds.contains(id2))
    }

    /// allSavedProjectEntries returns entries with projectId.
    func testAllSavedProjectEntries_containsProjectId() throws {
        let templateId = "tt11-\(UUID())"
        let store = ProjectStore()
        let projectId = UUID()
        let draft = ProjectDraft.create(for: templateId, projectId: projectId)

        var slot = ActiveDraftSlot(
            entryContext: .newFromTemplate(templateId: templateId),
            sourceTemplateId: templateId,
            linkedSavedProjectId: nil,
            draft: draft
        )
        try store.materializeSavedProject(from: &slot)
        defer { try? store.deleteSavedProject(projectId: projectId) }

        let entries = store.allSavedProjectEntries()
        let entry = entries.first { $0.projectId == projectId }
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.sourceTemplateId, templateId)
    }

    /// hasActiveDraft is correct.
    func testHasActiveDraft_correctness() throws {
        let store = ProjectStore()

        // Ensure clean state
        try? store.deleteActiveDraft()
        XCTAssertFalse(store.hasActiveDraft())

        let draft = ProjectDraft.create(for: "test-template")
        let slot = ActiveDraftSlot(
            entryContext: .newFromTemplate(templateId: "test-template"),
            sourceTemplateId: "test-template",
            linkedSavedProjectId: nil,
            draft: draft
        )
        try store.saveActiveDraft(slot)
        XCTAssertTrue(store.hasActiveDraft())

        try store.deleteActiveDraft()
        XCTAssertFalse(store.hasActiveDraft())
    }

    /// Empty draft roundtrips correctly through SavedProjectRecord.
    func testSavedProjectRecord_emptyDraft_roundtrip() throws {
        let templateId = "tt11-\(UUID())"
        let store = ProjectStore()
        let projectId = UUID()
        // Use whole-second dates to survive ISO8601 roundtrip
        let now = Date(timeIntervalSince1970: 1705312800)
        let draft = ProjectDraft(
            id: projectId,
            templateId: templateId,
            createdAt: now,
            updatedAt: now
        )

        var slot = ActiveDraftSlot(
            entryContext: .newFromTemplate(templateId: templateId),
            sourceTemplateId: templateId,
            linkedSavedProjectId: nil,
            draft: draft
        )
        try store.materializeSavedProject(from: &slot)
        defer { try? store.deleteSavedProject(projectId: projectId) }

        let loaded = store.loadSavedProject(projectId: projectId)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.draft, draft)
    }
}
