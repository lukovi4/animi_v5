import XCTest
import TVECore
@testable import AnimiApp

/// Covers the `excludedOverlayIds` hiding seam on the preview resolve path. The
/// live Core Animation text layer relies on this to omit exactly the committed
/// Metal copy of the overlay being transformed, so there is no ghost/duplicate.
/// The export resolve path never excludes anything (no `excludedOverlayIds`).
@MainActor
final class OverlayResolverExclusionTests: XCTestCase {

    private func makeDraft() -> ProjectDraft {
        var draft = ProjectDraft.create(origin: .template(templateId: "test-template"))
        var timeline = CanonicalTimeline.empty()
        let scenePid = UUID()
        timeline.payloads[scenePid] = .scene(ScenePayload(sceneTypeId: "scene_0"))
        timeline.tracks[0].items.append(
            TimelineItem(payloadId: scenePid, kind: .scene, startUs: nil, durationUs: 5_000_000)
        )
        draft.canonicalTimeline = timeline
        return draft
    }

    private func twoTextStore() -> (EditorStore, UUID, UUID) {
        let store = EditorStore.create(draft: makeDraft(), templateFPS: 30, defaultSceneSequence: [])
        store.dispatch(.addTextOverlay(text: "First", fontSize: 32, colorHex: "#FFFFFF", fontFamily: nil, startUs: 0, durationUs: 4_000_000))
        store.dispatch(.addTextOverlay(text: "Second", fontSize: 32, colorHex: "#FFFFFF", fontFamily: nil, startUs: 0, durationUs: 4_000_000))
        let items = store.state.canonicalTimeline.textItems
        return (store, items[0].id, items[1].id)
    }

    /// With no exclusion both text items resolve.
    func testNoExclusion_resolvesAllText() {
        let (store, _, _) = twoTextStore()
        let resolved = OverlayResolver.resolve(
            from: store.state.canonicalTimeline, at: 1_000_000, stickerProvider: nil
        ).filter { $0.kind == .text }
        XCTAssertEqual(resolved.count, 2)
    }

    /// Excluding one id omits exactly that item; the other still resolves.
    func testExclusion_omitsOnlyTheExcludedItem() {
        let (store, firstId, secondId) = twoTextStore()
        let resolved = OverlayResolver.resolve(
            from: store.state.canonicalTimeline,
            at: 1_000_000,
            stickerProvider: nil,
            excludedOverlayIds: [firstId]
        ).filter { $0.kind == .text }

        XCTAssertEqual(resolved.count, 1, "exactly one text item should remain")
        XCTAssertEqual(resolved.first?.stableId, secondId)
        XCTAssertFalse(resolved.contains { $0.stableId == firstId }, "excluded id must not be rendered")
    }

    /// An empty exclusion set is equivalent to the default (no items omitted).
    func testEmptyExclusion_equivalentToDefault() {
        let (store, _, _) = twoTextStore()
        let withEmpty = OverlayResolver.resolve(
            from: store.state.canonicalTimeline, at: 1_000_000, stickerProvider: nil, excludedOverlayIds: []
        )
        let withDefault = OverlayResolver.resolve(
            from: store.state.canonicalTimeline, at: 1_000_000, stickerProvider: nil
        )
        XCTAssertEqual(withEmpty.count, withDefault.count)
    }
}
