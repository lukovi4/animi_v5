import XCTest
@testable import AnimiApp

/// Tests for TemplateCatalogSnapshot.pruned(against:) validation layer
/// and shipped bundle consistency.
final class TemplateCatalogValidationTests: XCTestCase {

    // MARK: - Helpers

    private func makeLibrary(sceneIds: [String]) -> SceneLibrarySnapshot {
        let scenes = sceneIds.enumerated().map { i, id in
            SceneTypeDescriptor(
                id: id,
                order: i,
                title: "Scene \(id)",
                baseDurationUs: TimeUs(1_000_000)
            )
        }
        return SceneLibrarySnapshot(
            fps: 30,
            canvas: CanvasConfig(width: 1080, height: 1920),
            scenes: scenes
        )
    }

    private func makeSnapshot(
        categories: [(id: String, order: Int)],
        templates: [(id: String, categoryId: String, sceneTypeIds: [String])]
    ) -> TemplateCatalogSnapshot {
        let cats = categories.map {
            TemplateCategory(id: $0.id, title: $0.id, titleKey: nil, order: $0.order)
        }
        let tmpls = templates.enumerated().map { i, t in
            TemplateDescriptor(
                id: t.id,
                categoryId: t.categoryId,
                order: i,
                title: t.id,
                titleKey: nil,
                sceneTypeIds: t.sceneTypeIds,
                previewAsset: nil,
                openBehavior: .previewFirst
            )
        }
        return TemplateCatalogSnapshot(categories: cats, templates: tmpls)
    }

    // MARK: - Pruning Tests

    func test_validTemplateSurvivesPruning() {
        let library = makeLibrary(sceneIds: ["scene_a"])
        let snapshot = makeSnapshot(
            categories: [("cat1", 0)],
            templates: [("t1", "cat1", ["scene_a"])]
        )

        let pruned = snapshot.pruned(against: library)

        XCTAssertEqual(pruned.templates.count, 1)
        XCTAssertEqual(pruned.templates.first?.id, "t1")
        XCTAssertEqual(pruned.categories.count, 1)
    }

    func test_templateWithMissingSceneTypeIdIsDropped() {
        let library = makeLibrary(sceneIds: ["scene_a"])
        let snapshot = makeSnapshot(
            categories: [("cat1", 0)],
            templates: [
                ("t_valid", "cat1", ["scene_a"]),
                ("t_stale", "cat1", ["scene_missing"])
            ]
        )

        let pruned = snapshot.pruned(against: library)

        XCTAssertEqual(pruned.templates.count, 1)
        XCTAssertEqual(pruned.templates.first?.id, "t_valid")
    }

    func test_templateWithEmptySceneTypeIdsIsDropped() {
        let library = makeLibrary(sceneIds: ["scene_a"])
        let snapshot = makeSnapshot(
            categories: [("cat1", 0)],
            templates: [
                ("t_valid", "cat1", ["scene_a"]),
                ("t_empty", "cat1", [])
            ]
        )

        let pruned = snapshot.pruned(against: library)

        XCTAssertEqual(pruned.templates.count, 1)
        XCTAssertEqual(pruned.templates.first?.id, "t_valid")
    }

    func test_emptyCategoryDisappearsAfterPruning() {
        let library = makeLibrary(sceneIds: ["scene_a"])
        let snapshot = makeSnapshot(
            categories: [("featured", 0), ("polaroid", 1)],
            templates: [
                ("t1", "featured", ["scene_a"]),
                ("t2", "polaroid", ["scene_missing"])
            ]
        )

        let pruned = snapshot.pruned(against: library)

        XCTAssertEqual(pruned.categories.count, 1)
        XCTAssertEqual(pruned.categories.first?.id, "featured")
        // Also verify via categoriesInOrder which has the same filtering
        XCTAssertEqual(pruned.categoriesInOrder().count, 1)
    }

    func test_templateWithPartiallyMissingSceneTypeIdsIsDropped() {
        let library = makeLibrary(sceneIds: ["scene_a"])
        let snapshot = makeSnapshot(
            categories: [("cat1", 0)],
            templates: [("t_partial", "cat1", ["scene_a", "scene_missing"])]
        )

        let pruned = snapshot.pruned(against: library)

        XCTAssertEqual(pruned.templates.count, 0)
        XCTAssertEqual(pruned.categories.count, 0)
    }

    func test_pruningPreservesOrder() {
        let library = makeLibrary(sceneIds: ["s1", "s2", "s3"])
        let snapshot = makeSnapshot(
            categories: [("cat1", 0)],
            templates: [
                ("t1", "cat1", ["s1"]),
                ("t2", "cat1", ["s_missing"]),
                ("t3", "cat1", ["s3"])
            ]
        )

        let pruned = snapshot.pruned(against: library)

        XCTAssertEqual(pruned.templates.map(\.id), ["t1", "t3"])
    }

    // MARK: - Bundle Consistency

    /// Every template in the shipped manifest must reference only scene types
    /// present in the shipped scene library. If this test fails, manifest.json
    /// and library.json are out of sync.
    func test_shippedCatalogIsConsistentWithSceneLibrary() throws {
        let catalogLoader = BundleTemplateCatalogLoader()
        let sceneLoader = BundleSceneLibraryLoader()

        let rawCatalog = try catalogLoader.loadManifest()
        let library = try sceneLoader.load()

        for template in rawCatalog.templates {
            for sceneTypeId in template.sceneTypeIds {
                XCTAssertNotNil(
                    library.scene(byId: sceneTypeId),
                    "Template '\(template.id)' references scene '\(sceneTypeId)' which is missing from library.json"
                )
            }
        }
    }
}
