import XCTest
import Metal
import TVECore
@testable import AnimiApp

// MARK: - Test Preset Provider

private let testPresetId = "test_preset"
private let altPresetId = "alt_preset"
private let testRegionId = "full"

private struct TestPresetProvider: BackgroundPresetProviding {
    func loadFromBundle() throws {}
    var allPresets: [BackgroundPreset] { [Self.preset, Self.altPreset] }
    var count: Int { 2 }

    func preset(for presetId: String) -> BackgroundPreset? {
        switch presetId {
        case testPresetId: return Self.preset
        case altPresetId: return Self.altPreset
        default: return nil
        }
    }
    func presetOrFallback(for presetId: String) -> BackgroundPreset? {
        preset(for: presetId) ?? Self.preset
    }

    static let preset = BackgroundPreset(
        presetId: testPresetId,
        title: "Test",
        canvasSize: [1080, 1920],
        regions: [
            BackgroundRegionPreset(
                regionId: testRegionId,
                displayName: "Full",
                mask: BackgroundMask(
                    type: .polygon,
                    vertices: [
                        Vec2D(x: 0, y: 0),
                        Vec2D(x: 1080, y: 0),
                        Vec2D(x: 1080, y: 1920),
                        Vec2D(x: 0, y: 1920)
                    ]
                )
            )
        ]
    )

    static let altPreset = BackgroundPreset(
        presetId: altPresetId,
        title: "Alt",
        canvasSize: [1080, 1920],
        regions: [
            BackgroundRegionPreset(
                regionId: testRegionId,
                displayName: "Full",
                mask: BackgroundMask(
                    type: .polygon,
                    vertices: [
                        Vec2D(x: 0, y: 0),
                        Vec2D(x: 1080, y: 0),
                        Vec2D(x: 1080, y: 1920),
                        Vec2D(x: 0, y: 1920)
                    ]
                )
            )
        ]
    )
}

// MARK: - EffectiveBackgroundBuilder Resolver Tests

final class EffectiveBackgroundBuilderResolverTests: XCTestCase {

    private let presetLibrary = TestPresetProvider()

    func test_sceneOverride_beatsProjectDefault() {
        let projectOverride = ProjectBackgroundOverride(
            selectedPresetId: testPresetId,
            regions: [testRegionId: RegionOverride(source: .solid(colorHex: "#FF0000"))]
        )
        let sceneOverride = ProjectBackgroundOverride(
            selectedPresetId: testPresetId,
            regions: [testRegionId: RegionOverride(source: .solid(colorHex: "#00FF00"))]
        )

        let state = EffectiveBackgroundBuilder.build(
            templateBackground: nil,
            projectOverride: projectOverride,
            sceneOverride: sceneOverride,
            presetLibrary: presetLibrary
        )

        guard let regionState = state?.state(for: testRegionId),
              case .solid(let config) = regionState.source else {
            XCTFail("Expected solid region source")
            return
        }
        // Green from scene override, not red from project
        XCTAssertEqual(config.color.green, 1.0, accuracy: 0.01)
        XCTAssertEqual(config.color.red, 0.0, accuracy: 0.01)
    }

    func test_projectDefault_beatsTemplate() {
        let projectOverride = ProjectBackgroundOverride(
            selectedPresetId: testPresetId,
            regions: [testRegionId: RegionOverride(source: .solid(colorHex: "#0000FF"))]
        )

        let state = EffectiveBackgroundBuilder.build(
            templateBackground: nil,
            projectOverride: projectOverride,
            sceneOverride: nil,
            presetLibrary: presetLibrary
        )

        guard let regionState = state?.state(for: testRegionId),
              case .solid(let config) = regionState.source else {
            XCTFail("Expected solid region source")
            return
        }
        XCTAssertEqual(config.color.blue, 1.0, accuracy: 0.01)
    }

    func test_sceneOverride_fullyReplacesProjectBackground() {
        // Project has red color for the region
        let projectOverride = ProjectBackgroundOverride(
            selectedPresetId: testPresetId,
            regions: [testRegionId: RegionOverride(source: .solid(colorHex: "#FF0000"))]
        )
        // Scene override with different preset, no region entries
        let sceneOverride = ProjectBackgroundOverride(
            selectedPresetId: altPresetId,
            regions: [:]  // No regions — full replacement means project regions don't merge
        )

        let state = EffectiveBackgroundBuilder.build(
            templateBackground: nil,
            projectOverride: projectOverride,
            sceneOverride: sceneOverride,
            presetLibrary: presetLibrary
        )

        XCTAssertEqual(state?.preset.presetId, altPresetId, "Scene override preset should win")
        // Region should fall back to solid black (no scene region, no project region due to full replacement)
        guard let regionState = state?.state(for: testRegionId),
              case .solid(let config) = regionState.source else {
            XCTFail("Expected solid fallback")
            return
        }
        XCTAssertEqual(config.color.red, 0.0, accuracy: 0.01, "Should be black fallback, not red from project")
    }

    func test_nilSceneOverride_fallsToProjectDefault() {
        let projectOverride = ProjectBackgroundOverride(
            selectedPresetId: testPresetId,
            regions: [testRegionId: RegionOverride(source: .solid(colorHex: "#FF0000"))]
        )

        let state = EffectiveBackgroundBuilder.build(
            templateBackground: nil,
            projectOverride: projectOverride,
            sceneOverride: nil,
            presetLibrary: presetLibrary
        )

        guard let regionState = state?.state(for: testRegionId),
              case .solid(let config) = regionState.source else {
            XCTFail("Expected solid region source from project")
            return
        }
        XCTAssertEqual(config.color.red, 1.0, accuracy: 0.01)
    }

    func test_legacyBuildAPI_equivalentToNewWithNilScene() {
        let projectOverride = ProjectBackgroundOverride(
            selectedPresetId: testPresetId,
            regions: [testRegionId: RegionOverride(source: .solid(colorHex: "#AABBCC"))]
        )

        let legacy = EffectiveBackgroundBuilder.build(
            templateBackground: nil,
            projectOverride: projectOverride,
            presetLibrary: presetLibrary
        )
        let modern = EffectiveBackgroundBuilder.build(
            templateBackground: nil,
            projectOverride: projectOverride,
            sceneOverride: nil,
            presetLibrary: presetLibrary
        )

        XCTAssertEqual(legacy, modern)
    }
}

// MARK: - Persistence Round-Trip Tests

final class SceneBackgroundPersistenceTests: XCTestCase {

    func test_sceneState_backgroundOverride_roundTrip() throws {
        let override = ProjectBackgroundOverride(
            selectedPresetId: "my_preset",
            regions: [
                "top": RegionOverride(source: .solid(colorHex: "#FF0000")),
                "bottom": RegionOverride(source: .image(ImageOverride(
                    mediaRef: MediaRef(storagePath: "media/bg/img.jpg", mediaKind: .photo, assetId: ProjectAssetID()),
                    transform: .identity
                )))
            ]
        )
        let original = SceneState(backgroundOverride: override)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SceneState.self, from: data)

        XCTAssertEqual(original, decoded)
        XCTAssertNotNil(decoded.backgroundOverride)
        XCTAssertEqual(decoded.backgroundOverride?.selectedPresetId, "my_preset")
        XCTAssertEqual(decoded.backgroundOverride?.regions.count, 2)
    }

    func test_sceneState_nilBackgroundOverride_decodesFromOldJSON() throws {
        // JSON without backgroundOverride field — should decode as nil
        let json = """
        {"variantOverrides":{},"layerToggles":{}}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(SceneState.self, from: json)
        XCTAssertNil(decoded.backgroundOverride)
    }

    func test_regionSourceOverride_unknownType_throwsDecodingError() {
        let json = """
        {"type":"hologram","hologram":{}}
        """.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(RegionSourceOverride.self, from: json)) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                XCTFail("Expected dataCorrupted, got \(error)")
                return
            }
            XCTAssertTrue(context.debugDescription.contains("hologram"))
        }
    }

    func test_videoOverride_roundTrip() throws {
        let videoOverride = VideoOverride(
            mediaRef: MediaRef(storagePath: "media/bg/video.mp4", mediaKind: .video, assetId: ProjectAssetID()),
            loop: true,
            trimStart: 1.5,
            trimEnd: 10.0,
            startOffset: 0.5
        )
        let source = RegionSourceOverride.video(videoOverride)

        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(RegionSourceOverride.self, from: data)

        XCTAssertEqual(source, decoded)
        if case .video(let v) = decoded {
            XCTAssertEqual(v.loop, true)
            XCTAssertEqual(v.trimStart, 1.5)
            XCTAssertEqual(v.trimEnd, 10.0)
            XCTAssertEqual(v.startOffset, 0.5)
        } else {
            XCTFail("Expected .video case")
        }
    }

    func test_animatedOverride_roundTrip() throws {
        let animOverride = AnimatedOverride(
            mediaRef: MediaRef(storagePath: "media/bg/anim.gif", mediaKind: .photo, assetId: ProjectAssetID()),
            frameRate: 24.0,
            loop: false,
            trimStart: nil,
            trimEnd: nil,
            startOffset: 2.0
        )
        let source = RegionSourceOverride.animated(animOverride)

        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(RegionSourceOverride.self, from: data)

        XCTAssertEqual(source, decoded)
        if case .animated(let a) = decoded {
            XCTAssertEqual(a.frameRate, 24.0)
            XCTAssertEqual(a.loop, false)
            XCTAssertEqual(a.startOffset, 2.0)
        } else {
            XCTFail("Expected .animated case")
        }
    }
}

// MARK: - ProjectAssetRegistry Walker Tests

final class SceneBackgroundAssetWalkerTests: XCTestCase {

    private func makeDraft(
        projectBgRegions: [String: RegionOverride] = [:],
        sceneStates: [UUID: SceneState] = [:]
    ) -> ProjectDraft {
        ProjectDraft(
            origin: .template(templateId: "test"),
            background: ProjectBackgroundOverride(regions: projectBgRegions),
            sceneInstanceStates: sceneStates
        )
    }

    func test_assetIds_includesSceneBackgroundImageRefs() {
        let assetId = ProjectAssetID()
        let mediaRef = MediaRef(storagePath: "media/bg/scene_bg.jpg", mediaKind: .photo, assetId: assetId)
        let sceneState = SceneState(
            backgroundOverride: ProjectBackgroundOverride(
                regions: ["full": RegionOverride(source: .image(ImageOverride(mediaRef: mediaRef)))]
            )
        )
        let draft = makeDraft(sceneStates: [UUID(): sceneState])

        let ids = draft.assetRegistry.assetIds(referencedBy: draft)
        XCTAssertTrue(ids.contains(assetId))
    }

    func test_assetIds_includesSceneBackgroundVideoRefs() {
        let assetId = ProjectAssetID()
        let mediaRef = MediaRef(storagePath: "media/bg/scene_bg.mp4", mediaKind: .video, assetId: assetId)
        let sceneState = SceneState(
            backgroundOverride: ProjectBackgroundOverride(
                regions: ["full": RegionOverride(source: .video(VideoOverride(mediaRef: mediaRef)))]
            )
        )
        let draft = makeDraft(sceneStates: [UUID(): sceneState])

        let ids = draft.assetRegistry.assetIds(referencedBy: draft)
        XCTAssertTrue(ids.contains(assetId))
    }

    func test_storagePaths_includesSceneBackgroundRefs() {
        let assetId = ProjectAssetID()
        let storagePath = "media/bg/scene_bg.jpg"
        let mediaRef = MediaRef(storagePath: storagePath, mediaKind: .photo, assetId: assetId)
        let sceneState = SceneState(
            backgroundOverride: ProjectBackgroundOverride(
                regions: ["full": RegionOverride(source: .image(ImageOverride(mediaRef: mediaRef)))]
            )
        )
        let draft = makeDraft(sceneStates: [UUID(): sceneState])

        let paths = draft.assetRegistry.storagePaths(referencedBy: draft)
        XCTAssertTrue(paths.contains(storagePath))
    }

    // MARK: - Project-level video/animated walker tests

    func test_assetIds_includesProjectBackgroundVideoRefs() {
        let assetId = ProjectAssetID()
        let mediaRef = MediaRef(storagePath: "media/bg/project_bg.mp4", mediaKind: .video, assetId: assetId)
        let draft = makeDraft(
            projectBgRegions: ["full": RegionOverride(source: .video(VideoOverride(mediaRef: mediaRef)))]
        )

        let ids = draft.assetRegistry.assetIds(referencedBy: draft)
        XCTAssertTrue(ids.contains(assetId))
    }

    func test_assetIds_includesProjectBackgroundAnimatedRefs() {
        let assetId = ProjectAssetID()
        let mediaRef = MediaRef(storagePath: "media/bg/project_bg.gif", mediaKind: .photo, assetId: assetId)
        let draft = makeDraft(
            projectBgRegions: ["full": RegionOverride(source: .animated(AnimatedOverride(mediaRef: mediaRef)))]
        )

        let ids = draft.assetRegistry.assetIds(referencedBy: draft)
        XCTAssertTrue(ids.contains(assetId))
    }

    func test_storagePaths_includesProjectBackgroundVideoRefs() {
        let assetId = ProjectAssetID()
        let storagePath = "media/bg/project_bg.mp4"
        let mediaRef = MediaRef(storagePath: storagePath, mediaKind: .video, assetId: assetId)
        let draft = makeDraft(
            projectBgRegions: ["full": RegionOverride(source: .video(VideoOverride(mediaRef: mediaRef)))]
        )

        let paths = draft.assetRegistry.storagePaths(referencedBy: draft)
        XCTAssertTrue(paths.contains(storagePath))
    }

    func test_selfHealed_synthesizesProjectBackgroundVideoDescriptors() {
        let assetId = ProjectAssetID()
        let storagePath = "media/bg/project_bg.mp4"
        let mediaRef = MediaRef(storagePath: storagePath, mediaKind: .video, assetId: assetId)
        var draft = makeDraft(
            projectBgRegions: ["full": RegionOverride(source: .video(VideoOverride(mediaRef: mediaRef)))]
        )
        draft.assetRegistry = ProjectAssetRegistry()

        let healed = draft.assetRegistry.selfHealed(for: draft)
        XCTAssertNotNil(healed.descriptor(for: assetId))
        XCTAssertEqual(healed.storagePath(for: assetId), storagePath)
    }

    func test_selfHealed_synthesizesSceneBackgroundDescriptors() {
        let assetId = ProjectAssetID()
        let storagePath = "media/bg/scene_bg.jpg"
        let mediaRef = MediaRef(storagePath: storagePath, mediaKind: .photo, assetId: assetId)
        let sceneState = SceneState(
            backgroundOverride: ProjectBackgroundOverride(
                regions: ["full": RegionOverride(source: .image(ImageOverride(mediaRef: mediaRef)))]
            )
        )
        var draft = makeDraft(sceneStates: [UUID(): sceneState])
        // Registry has no descriptor for this asset
        draft.assetRegistry = ProjectAssetRegistry()

        let healed = draft.assetRegistry.selfHealed(for: draft)
        XCTAssertNotNil(healed.descriptor(for: assetId))
        XCTAssertEqual(healed.storagePath(for: assetId), storagePath)
    }
}

// MARK: - ExportBackgroundSnapshot Scene-Aware Tests

final class ExportBackgroundSnapshotSceneTests: XCTestCase {

    private let presetLibrary = TestPresetProvider()

    func test_sceneOverride_usedForExportSnapshot() {
        let projectOverride = ProjectBackgroundOverride(
            selectedPresetId: testPresetId,
            regions: ["full": RegionOverride(source: .solid(colorHex: "#FF0000"))]
        )
        let sceneMediaRef = MediaRef(storagePath: "media/bg/scene.jpg", mediaKind: .photo, assetId: ProjectAssetID())
        let sceneOverride = ProjectBackgroundOverride(
            selectedPresetId: testPresetId,
            regions: ["full": RegionOverride(source: .image(ImageOverride(mediaRef: sceneMediaRef)))]
        )

        let effState = EffectiveBackgroundBuilder.build(
            templateBackground: nil,
            projectOverride: projectOverride,
            sceneOverride: sceneOverride,
            presetLibrary: presetLibrary
        )

        let snapshot = ExportBackgroundSnapshot.build(
            from: projectOverride,
            sceneOverride: sceneOverride,
            effectiveState: effState
        )

        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.regionRefs.count, 1)
        XCTAssertEqual(snapshot?.regionRefs.first?.mediaRef.storagePath, "media/bg/scene.jpg")
    }

    func test_nilSceneOverride_fallsToProject() {
        let projectMediaRef = MediaRef(storagePath: "media/bg/project.jpg", mediaKind: .photo, assetId: ProjectAssetID())
        let projectOverride = ProjectBackgroundOverride(
            selectedPresetId: testPresetId,
            regions: ["full": RegionOverride(source: .image(ImageOverride(mediaRef: projectMediaRef)))]
        )

        let effState = EffectiveBackgroundBuilder.build(
            templateBackground: nil,
            projectOverride: projectOverride,
            sceneOverride: nil,
            presetLibrary: presetLibrary
        )

        let snapshot = ExportBackgroundSnapshot.build(
            from: projectOverride,
            sceneOverride: nil,
            effectiveState: effState
        )

        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.regionRefs.first?.mediaRef.storagePath, "media/bg/project.jpg")
    }
}

// MARK: - withReplacedMediaRef Tests

final class RegionSourceOverrideMediaRefTests: XCTestCase {

    func test_withReplacedMediaRef_image() {
        let oldRef = MediaRef(storagePath: "old.jpg", mediaKind: .photo, assetId: ProjectAssetID())
        let newRef = MediaRef(storagePath: "new.jpg", mediaKind: .photo, assetId: ProjectAssetID())
        let source = RegionSourceOverride.image(ImageOverride(mediaRef: oldRef))

        let replaced = source.withReplacedMediaRef(newRef)

        if case .image(let img) = replaced {
            XCTAssertEqual(img.mediaRef.storagePath, "new.jpg")
        } else {
            XCTFail("Expected .image case")
        }
    }

    func test_withReplacedMediaRef_video() {
        let oldRef = MediaRef(storagePath: "old.mp4", mediaKind: .video, assetId: ProjectAssetID())
        let newRef = MediaRef(storagePath: "new.mp4", mediaKind: .video, assetId: ProjectAssetID())
        let source = RegionSourceOverride.video(VideoOverride(mediaRef: oldRef, loop: true, trimStart: 1.0))

        let replaced = source.withReplacedMediaRef(newRef)

        if case .video(let vid) = replaced {
            XCTAssertEqual(vid.mediaRef.storagePath, "new.mp4")
            XCTAssertEqual(vid.loop, true)
            XCTAssertEqual(vid.trimStart, 1.0)
        } else {
            XCTFail("Expected .video case")
        }
    }

    func test_withReplacedMediaRef_solid_noChange() {
        let ref = MediaRef(storagePath: "x.jpg", mediaKind: .photo, assetId: ProjectAssetID())
        let source = RegionSourceOverride.solid(colorHex: "#FF0000")

        let replaced = source.withReplacedMediaRef(ref)
        XCTAssertEqual(replaced, source)
    }
}

// MARK: - RegionOverride.mediaRef Tests

final class RegionOverrideMediaRefTests: XCTestCase {

    func test_mediaRef_returnsNilForSolid() {
        let region = RegionOverride(source: .solid(colorHex: "#000"))
        XCTAssertNil(region.mediaRef)
    }

    func test_mediaRef_returnsRefForImage() {
        let ref = MediaRef(storagePath: "img.jpg", mediaKind: .photo, assetId: ProjectAssetID())
        let region = RegionOverride(source: .image(ImageOverride(mediaRef: ref)))
        XCTAssertEqual(region.mediaRef?.storagePath, "img.jpg")
    }

    func test_mediaRef_returnsRefForVideo() {
        let ref = MediaRef(storagePath: "vid.mp4", mediaKind: .video, assetId: ProjectAssetID())
        let region = RegionOverride(source: .video(VideoOverride(mediaRef: ref)))
        XCTAssertEqual(region.mediaRef?.storagePath, "vid.mp4")
    }

    func test_mediaRef_returnsRefForAnimated() {
        let ref = MediaRef(storagePath: "anim.gif", mediaKind: .photo, assetId: ProjectAssetID())
        let region = RegionOverride(source: .animated(AnimatedOverride(mediaRef: ref)))
        XCTAssertEqual(region.mediaRef?.storagePath, "anim.gif")
    }
}

// MARK: - Runtime-Level Session Factory

@MainActor
private func makeBootedRuntimeWithColorBackground(
    projectColorHex: String = "#FF0000",
    sceneColorHex: String? = nil,
    sceneCount: Int = 1,
    transitionType: AnimiApp.TransitionType? = nil
) async -> (EditorSession, EditorRuntime, [UUID])? {
    let projectOverride = ProjectBackgroundOverride(
        selectedPresetId: testPresetId,
        regions: [testRegionId: RegionOverride(source: .solid(colorHex: projectColorHex))]
    )

    let sceneTypeDefaults: [SceneTypeDefault] = (0..<sceneCount).map { _ in
        SceneTypeDefault(sceneTypeId: "scene_1", baseDurationUs: 3_000_000)
    }

    let deps = EditorSessionDependencies(
        saveActiveDraft: { _ in },
        loadActiveDraft: { nil },
        deleteActiveDraft: {},
        loadSavedProject: { _ in nil },
        materializeSavedProject: { $0 },
        mediaLocator: TestMediaLocator(resolvedURL: URL(fileURLWithPath: "/tmp/stub")),
        mediaWriter: TestMediaWriter(),
        loadSceneLibrary: {
            SceneLibrarySnapshot(
                fps: 30,
                canvas: CanvasConfig(width: 1080, height: 1920),
                scenes: [
                    SceneTypeDescriptor(id: "scene_1", order: 0, title: "Test", baseDurationUs: 3_000_000)
                ]
            )
        },
        sceneTypeDefaults: { _, _ in sceneTypeDefaults },
        loadTemplateCatalog: {
            .success(TemplateCatalogSnapshot(categories: [], templates: []))
        },
        backgroundPresetProvider: TestPresetProvider()
    )

    let session = EditorSession(intent: .template(templateId: "tpl_1"), dependencies: deps)
    await session.bootstrap()

    session.dispatch(.setBackground(projectOverride))

    guard let editorState = session.state else { return nil }
    let sceneInstanceIds = editorState.draft.canonicalTimeline.sceneItems.map(\.id)

    // Set scene override if requested (on the last scene for multi-scene, or the only scene)
    if let sceneHex = sceneColorHex, let lastId = sceneInstanceIds.last {
        let sceneOverride = ProjectBackgroundOverride(
            selectedPresetId: testPresetId,
            regions: [testRegionId: RegionOverride(source: .solid(colorHex: sceneHex))]
        )
        session.setSceneBackgroundOverride(sceneOverride, for: lastId)
    }

    // Set transition if multi-scene
    if let tType = transitionType, sceneInstanceIds.count >= 2 {
        let transition = SceneTransition(type: tType, durationFrames: 14, easingPreset: .easeInOut)
        session.dispatch(.setBoundaryTransition(
            fromSceneId: sceneInstanceIds[0],
            toSceneId: sceneInstanceIds[1],
            transition: transition
        ))
    }

    guard let updatedState = session.state else { return nil }
    guard let device = MTLCreateSystemDefaultDevice(),
          let commandQueue = device.makeCommandQueue() else { return nil }

    let runtime = EditorRuntime(session: session)
    let metalContext = EditorRuntimeMetalContext(
        device: device,
        commandQueue: commandQueue,
        colorPixelFormat: .bgra8Unorm
    )
    let library = SceneLibrarySnapshot(
        fps: 30,
        canvas: CanvasConfig(width: 1080, height: 1920),
        scenes: [
            SceneTypeDescriptor(id: "scene_1", order: 0, title: "Test", baseDurationUs: 3_000_000)
        ]
    )

    let loadResult = makeLoadResult(device: device)
    runtime.configureAndBoot(
        metalContext: metalContext,
        library: library,
        loadResult: loadResult,
        editorState: updatedState
    )

    await Task.yield()
    await Task.yield()

    return (session, runtime, sceneInstanceIds)
}

private struct TestMediaLocator: ProjectMediaLocator {
    let resolvedURL: URL
    func absoluteURL(for mediaRef: MediaRef, registry: ProjectAssetRegistry) async throws -> URL {
        resolvedURL
    }
}

private struct TestMediaWriter: ProjectMediaWriteGateway {
    func saveBackgroundImage(from preparedFileURL: URL) async throws -> (MediaRef, URL) {
        (MediaRef(storagePath: "stub.jpg"), URL(fileURLWithPath: "/tmp/stub"))
    }
    func saveUserMedia(from fileURL: URL, mediaKind: MediaKind, filename: String) async throws -> (MediaRef, URL) {
        (MediaRef(storagePath: "stub.jpg"), URL(fileURLWithPath: "/tmp/stub"))
    }
    func deleteMediaFile(_ mediaRef: MediaRef) async throws {}
    func duplicateAssets(inDraft sourceDraft: ProjectDraft) async throws -> ProjectDraft { sourceDraft }
}

// MARK: - Runtime-Level Background Assertion Helpers

private func assertSolidColor(
    _ state: EffectiveBackgroundState?,
    regionId: String = testRegionId,
    red: Double? = nil,
    green: Double? = nil,
    blue: Double? = nil,
    message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard let regionState = state?.state(for: regionId),
          case .solid(let config) = regionState.source else {
        XCTFail("Expected solid region source. \(message)", file: file, line: line)
        return
    }
    if let r = red {
        XCTAssertEqual(config.color.red, r, accuracy: 0.01, "Red mismatch. \(message)", file: file, line: line)
    }
    if let g = green {
        XCTAssertEqual(config.color.green, g, accuracy: 0.01, "Green mismatch. \(message)", file: file, line: line)
    }
    if let b = blue {
        XCTAssertEqual(config.color.blue, b, accuracy: 0.01, "Blue mismatch. \(message)", file: file, line: line)
    }
}

// MARK: - Timeline Preview Background Switch Tests

/// Verifies that `handlePlayheadChanged` switches background when crossing scene boundaries.
@MainActor
final class TimelinePreviewBackgroundSwitchTests: XCTestCase {

    // Shared setup: 2 scenes, A = red (project), B = green (scene override), fade transition.
    // At 30fps, each scene = 90 frames (3s). Transition = 14 frames around boundary (frame ~83..97).
    private func makeTwoSceneRuntime() async throws -> (EditorRuntime, [UUID]) {
        guard let (_, runtime, sceneIds) = await makeBootedRuntimeWithColorBackground(
            projectColorHex: "#FF0000",
            sceneColorHex: "#00FF00",
            sceneCount: 2,
            transitionType: .fade
        ) else {
            throw XCTSkip("Metal or session not available")
        }
        XCTAssertEqual(sceneIds.count, 2)
        return (runtime, sceneIds)
    }

    func test_timelinePreview_singleFrame_usesResolvedSingleSceneBackground() async throws {
        let (runtime, _) = try await makeTwoSceneRuntime()
        runtime.handlePlayheadChanged(40)
        assertSolidColor(
            runtime.effectiveBackgroundState,
            red: 1.0, green: 0.0,
            message: "Scene A should show red (project background)"
        )
    }

    func test_timelinePreview_transitionFrame_usesOutgoingSceneBackground() async throws {
        let (runtime, _) = try await makeTwoSceneRuntime()
        runtime.handlePlayheadChanged(90)
        assertSolidColor(
            runtime.effectiveBackgroundState,
            red: 1.0, green: 0.0,
            message: "During transition, background stays red (outgoing scene A)"
        )
    }

    func test_timelinePreview_postTransitionFrame_switchesToIncomingSceneBackground() async throws {
        let (runtime, _) = try await makeTwoSceneRuntime()
        runtime.handlePlayheadChanged(110)
        assertSolidColor(
            runtime.effectiveBackgroundState,
            red: 0.0, green: 1.0,
            message: "Scene B should show green (scene override)"
        )
    }

    func test_timelinePreview_switchesBackgroundOnFirstNonTransitionFrame() async throws {
        let (runtime, _) = try await makeTwoSceneRuntime()

        runtime.handlePlayheadChanged(40)
        assertSolidColor(
            runtime.effectiveBackgroundState,
            red: 1.0, green: 0.0,
            message: "Scene A should show red (project background)"
        )

        runtime.handlePlayheadChanged(90)
        assertSolidColor(
            runtime.effectiveBackgroundState,
            red: 1.0, green: 0.0,
            message: "During transition, background stays red"
        )

        runtime.handlePlayheadChanged(110)
        assertSolidColor(
            runtime.effectiveBackgroundState,
            red: 0.0, green: 1.0,
            message: "Scene B should show green (scene override)"
        )
    }
}

// MARK: - Scene Type Switch Background Recompute Tests

/// Verifies that after a coordinator scene-type load, the runtime recomputes
/// effective background from the new compiledScene's template background.
@MainActor
final class SceneTypeSwitchBackgroundTests: XCTestCase {

    func test_sceneTypeSwitch_recomputesTemplateBackground() async throws {
        // Boot with no project override → template is the only background source.
        // Initial scene has background=nil → solid black fallback.
        let deps = EditorSessionDependencies(
            saveActiveDraft: { _ in },
            loadActiveDraft: { nil },
            deleteActiveDraft: {},
            loadSavedProject: { _ in nil },
            materializeSavedProject: { $0 },
            mediaLocator: TestMediaLocator(resolvedURL: URL(fileURLWithPath: "/tmp/stub")),
            mediaWriter: TestMediaWriter(),
            loadSceneLibrary: {
                SceneLibrarySnapshot(
                    fps: 30,
                    canvas: CanvasConfig(width: 1080, height: 1920),
                    scenes: [
                        SceneTypeDescriptor(id: "scene_1", order: 0, title: "Test", baseDurationUs: 3_000_000)
                    ]
                )
            },
            sceneTypeDefaults: { _, _ in
                [SceneTypeDefault(sceneTypeId: "scene_1", baseDurationUs: 3_000_000)]
            },
            loadTemplateCatalog: {
                .success(TemplateCatalogSnapshot(categories: [], templates: []))
            },
            backgroundPresetProvider: TestPresetProvider()
        )

        let session = EditorSession(intent: .template(templateId: "tpl_1"), dependencies: deps)
        await session.bootstrap()

        guard let editorState = session.state else {
            throw XCTSkip("Session not available")
        }
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal not available")
        }

        let runtime = EditorRuntime(session: session)
        let metalContext = EditorRuntimeMetalContext(
            device: device,
            commandQueue: commandQueue,
            colorPixelFormat: .bgra8Unorm
        )
        let library = SceneLibrarySnapshot(
            fps: 30,
            canvas: CanvasConfig(width: 1080, height: 1920),
            scenes: [
                SceneTypeDescriptor(id: "scene_1", order: 0, title: "Test", baseDurationUs: 3_000_000)
            ]
        )

        // Boot with scene type A: background = nil → fallback solid black
        let loadResultA = makeLoadResult(device: device, templateBackground: nil)
        runtime.configureAndBoot(
            metalContext: metalContext,
            library: library,
            loadResult: loadResultA,
            editorState: editorState
        )

        assertSolidColor(
            runtime.effectiveBackgroundState,
            red: 0.0, green: 0.0, blue: 0.0,
            message: "Initial: no template bg → solid black fallback"
        )

        // TODO: EditorRuntime does not yet expose a simulateSceneTypeLoaded entry point.
        // Re-enable once the scene-type-switch API is added.
        throw XCTSkip("simulateSceneTypeLoaded not yet available on EditorRuntime")
    }
}

@MainActor
private func makeLoadResult(
    device: MTLDevice,
    templateBackground: Background? = nil
) -> EditorRuntime.InitialSceneLoadResult {
    let compiled = makeCompiledScene(device: device, templateBackground: templateBackground)
    let resolver = CompositeAssetResolver(localIndex: .empty, sharedIndex: .empty)
    let provider = ScenePackageTextureProvider(
        device: device,
        assetIndex: compiled.mergedAssetIndex,
        resolver: resolver,
        bindingAssetIds: compiled.bindingAssetIds
    )
    let player = ScenePlayer()
    let loaded = player.loadCompiledScene(compiled)
    return EditorRuntime.InitialSceneLoadResult(
        player: player,
        compiled: loaded,
        provider: provider,
        resolver: resolver,
        preloadStats: nil
    )
}

@MainActor
private func makeCompiledScene(
    device: MTLDevice,
    templateBackground: Background? = nil
) -> CompiledScene {
    let canvas = Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 90)
    let scene = Scene(
        schemaVersion: "1.0",
        sceneId: "scene_1",
        canvas: canvas,
        background: templateBackground,
        mediaBlocks: []
    )
    let runtime = SceneRuntime(
        scene: scene,
        canvas: canvas,
        blocks: [],
        durationFrames: 90,
        fps: 30
    )
    return CompiledScene(
        runtime: runtime,
        mergedAssetIndex: AssetIndexIR(),
        pathRegistry: PathRegistry(),
        bindingAssetIds: []
    )
}

// MARK: - Per-Scene Timeline Export Background Tests

/// Verifies that timeline export builds per-scene background data
/// using each scene's own template/override chain, not a single global state.
@MainActor
final class PerSceneTimelineExportBackgroundTests: XCTestCase {

    func test_sceneOverride_wins_inPerSceneExportData() {
        // Project = red solid, scene override = green solid
        let projectOverride = ProjectBackgroundOverride(
            selectedPresetId: testPresetId,
            regions: [testRegionId: RegionOverride(source: .solid(colorHex: "#FF0000"))]
        )
        let sceneOverride = ProjectBackgroundOverride(
            selectedPresetId: testPresetId,
            regions: [testRegionId: RegionOverride(source: .solid(colorHex: "#00FF00"))]
        )

        let effState = EffectiveBackgroundBuilder.build(
            templateBackground: nil,
            projectOverride: projectOverride,
            sceneOverride: sceneOverride,
            presetLibrary: TestPresetProvider()
        )

        // Scene override should win → green
        XCTAssertNotNil(effState)
        if let regionState = effState?.regionStates[testRegionId],
           case .solid(let solid) = regionState.source {
            XCTAssertEqual(solid.color.green, 1.0, accuracy: 0.01, "Scene override should win over project")
        } else {
            XCTFail("Expected solid region state")
        }
    }

    func test_noSceneOverride_usesProjectFallback() {
        let projectOverride = ProjectBackgroundOverride(
            selectedPresetId: testPresetId,
            regions: [testRegionId: RegionOverride(source: .solid(colorHex: "#FF0000"))]
        )

        let effState = EffectiveBackgroundBuilder.build(
            templateBackground: nil,
            projectOverride: projectOverride,
            sceneOverride: nil,
            presetLibrary: TestPresetProvider()
        )

        XCTAssertNotNil(effState)
        if let regionState = effState?.regionStates[testRegionId],
           case .solid(let solid) = regionState.source {
            XCTAssertEqual(solid.color.red, 1.0, accuracy: 0.01, "Project fallback should apply when no scene override")
        } else {
            XCTFail("Expected solid region state")
        }
    }

    func test_imageSnapshot_usesSceneOverrideRefs_whenPresent() {
        let projectMediaRef = MediaRef(storagePath: "media/bg/project.jpg", mediaKind: .photo, assetId: ProjectAssetID())
        let sceneMediaRef = MediaRef(storagePath: "media/bg/scene.jpg", mediaKind: .photo, assetId: ProjectAssetID())

        let projectOverride = ProjectBackgroundOverride(
            selectedPresetId: testPresetId,
            regions: [testRegionId: RegionOverride(source: .image(ImageOverride(mediaRef: projectMediaRef)))]
        )
        let sceneOverride = ProjectBackgroundOverride(
            selectedPresetId: testPresetId,
            regions: [testRegionId: RegionOverride(source: .image(ImageOverride(mediaRef: sceneMediaRef)))]
        )

        let effState = EffectiveBackgroundBuilder.build(
            templateBackground: nil,
            projectOverride: projectOverride,
            sceneOverride: sceneOverride,
            presetLibrary: TestPresetProvider()
        )

        // Scene override snapshot should use scene media ref, not project
        let bgSnapshot = ExportBackgroundSnapshot.build(
            from: projectOverride,
            sceneOverride: sceneOverride,
            effectiveState: effState
        )
        XCTAssertNotNil(bgSnapshot)
        XCTAssertEqual(bgSnapshot?.regionRefs.first?.mediaRef.storagePath, "media/bg/scene.jpg",
                       "Export snapshot should use scene override media refs")
    }

    func test_transitionFrame_usesOutgoingSceneBackground() {
        let sceneAId = UUID()
        let sceneBId = UUID()

        // Build two distinct background states: red for A, green for B.
        let redState = EffectiveBackgroundBuilder.build(
            templateBackground: nil,
            projectOverride: ProjectBackgroundOverride(
                selectedPresetId: testPresetId,
                regions: [testRegionId: RegionOverride(source: .solid(colorHex: "#FF0000"))]
            ),
            sceneOverride: nil,
            presetLibrary: TestPresetProvider()
        )
        let greenState = EffectiveBackgroundBuilder.build(
            templateBackground: nil,
            projectOverride: ProjectBackgroundOverride(
                selectedPresetId: testPresetId,
                regions: [testRegionId: RegionOverride(source: .solid(colorHex: "#00FF00"))]
            ),
            sceneOverride: nil,
            presetLibrary: TestPresetProvider()
        )

        let sceneBackgrounds: [UUID: SceneExportBackgroundData] = [
            sceneAId: SceneExportBackgroundData(state: redState, snapshot: nil),
            sceneBId: SceneExportBackgroundData(state: greenState, snapshot: nil),
        ]

        // Build a transition frame with sceneA = sceneAId.
        let canvasSize = SizeD(width: 1080, height: 1920)
        let ctxA = SceneRenderContext(
            commands: [], textureProvider: InMemoryTextureProvider(),
            pathRegistry: PathRegistry(), assetSizes: [:],
            localFrame: 0, canvasSize: canvasSize, sceneInstanceId: sceneAId
        )
        let ctxB = SceneRenderContext(
            commands: [], textureProvider: InMemoryTextureProvider(),
            pathRegistry: PathRegistry(), assetSizes: [:],
            localFrame: 0, canvasSize: canvasSize, sceneInstanceId: sceneBId
        )
        let resolved = ResolvedTimelineFrame.transition(TransitionRenderContext(
            sceneA: ctxA, sceneB: ctxB,
            transition: SceneTransition(type: .fade, durationFrames: 10),
            progress: 0.5
        ))

        let result = TimelineVideoExportRunner.resolveFrameBackground(
            resolved: resolved, sceneBackgrounds: sceneBackgrounds
        )

        XCTAssertEqual(result, redState, "Transition frames must use outgoing scene (A) background")
    }
}

// MARK: - Background Editor Preview Tests (Runtime-Level)

/// Verifies the background editor preview contract via the actual `applyBackgroundPreviewOverride` method.
@MainActor
final class BackgroundEditorPreviewTests: XCTestCase {

    func test_applyBackgroundPreviewOverride_sceneOverrideWins() async throws {
        // Scene override = green on active scene
        guard let (_, runtime, _) = await makeBootedRuntimeWithColorBackground(
            projectColorHex: "#FF0000",
            sceneColorHex: "#00FF00"
        ) else {
            throw XCTSkip("Metal or session not available")
        }

        // Editor sends blue as project-level preview
        let blueOverride = ProjectBackgroundOverride(
            selectedPresetId: testPresetId,
            regions: [testRegionId: RegionOverride(source: .solid(colorHex: "#0000FF"))]
        )
        runtime.applyBackgroundPreviewOverride(blueOverride)

        // Scene override (green) wins over editor's project-level blue
        assertSolidColor(
            runtime.effectiveBackgroundState,
            red: 0.0, green: 1.0, blue: 0.0,
            message: "Scene override should win over editor's project-level override"
        )
    }

    func test_applyBackgroundPreviewOverride_noSceneOverride_editorApplies() async throws {
        // No scene override
        guard let (_, runtime, _) = await makeBootedRuntimeWithColorBackground(
            projectColorHex: "#FF0000"
        ) else {
            throw XCTSkip("Metal or session not available")
        }

        // Editor sends blue
        let blueOverride = ProjectBackgroundOverride(
            selectedPresetId: testPresetId,
            regions: [testRegionId: RegionOverride(source: .solid(colorHex: "#0000FF"))]
        )
        runtime.applyBackgroundPreviewOverride(blueOverride)

        assertSolidColor(
            runtime.effectiveBackgroundState,
            red: 0.0, blue: 1.0,
            message: "Editor's blue should apply when no scene override"
        )
    }
}

// MARK: - BackgroundTextureService Stale Guard Tests

@MainActor
final class BackgroundTextureServiceStaleGuardTests: XCTestCase {

    func test_loadTexture_stale_skipsSetTexture_returnsFalse() async throws {
        let tempURL = try createTestImageFile()
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

        // isStale always returns true
        let written = try await service.loadTexture(
            slotKey: "bg/test/stale",
            mediaRef: mediaRef,
            assetRegistry: ProjectAssetRegistry(),
            isStale: { true }
        )

        XCTAssertFalse(written, "Should not write when stale")
        XCTAssertNil(provider.texture(for: "bg/test/stale"), "No texture should be in provider")
        XCTAssertFalse(service.isLoaded("bg/test/stale"))
    }

    func test_preloadTextures_stale_midBatch_stopsEarly() async throws {
        let tempURL = try createTestImageFile()
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

        // Build override with multiple image regions
        var override = ProjectBackgroundOverride.empty
        override.regions["r1"] = RegionOverride(source: .image(ImageOverride(mediaRef: mediaRef)))
        override.regions["r2"] = RegionOverride(source: .image(ImageOverride(mediaRef: mediaRef)))
        override.regions["r3"] = RegionOverride(source: .image(ImageOverride(mediaRef: mediaRef)))

        // isStale returns true immediately — should load 0 textures
        let loaded = await service.preloadTextures(
            from: override,
            presetId: "test",
            assetRegistry: ProjectAssetRegistry(),
            isStale: { true }
        )

        XCTAssertTrue(loaded.isEmpty, "Should stop early when stale")
    }

    // MARK: - Helpers

    private func createTestImageFile() throws -> URL {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context = CGContext(
            data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400,
            space: colorSpace, bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw NSError(domain: "Test", code: -1)
        }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        guard let cgImage = context.makeImage() else {
            throw NSError(domain: "Test", code: -1)
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_bg_\(UUID().uuidString).png")
        guard let dest = CGImageDestinationCreateWithURL(tempURL as CFURL, "public.png" as CFString, 1, nil) else {
            throw NSError(domain: "Test", code: -1)
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "Test", code: -1)
        }
        return tempURL
    }
}

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
