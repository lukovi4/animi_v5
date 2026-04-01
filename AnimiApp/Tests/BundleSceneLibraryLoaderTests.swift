import XCTest
@testable import AnimiApp

/// Tests for BundleSceneLibraryLoader loadability hardening.
final class BundleSceneLibraryLoaderTests: XCTestCase {

    // MARK: - Shipped Bundle Tests

    /// Every scene declared in shipped library.json must pass the real loadability probe.
    /// Compares raw manifest entries against the hardened snapshot to catch silently dropped scenes.
    func test_shippedScenesAreAllLoadable() throws {
        // Load raw manifest to get the full declared scene list
        let manifestURL = try XCTUnwrap(
            Bundle.main.url(forResource: "library", withExtension: "json", subdirectory: "Scenes")
        )
        let data = try Data(contentsOf: manifestURL)
        let rawManifest = try JSONDecoder().decode(SceneLibraryManifest.self, from: data)

        // Load hardened snapshot (filters by loadability)
        let loader = BundleSceneLibraryLoader()
        let snapshot = try loader.load()

        // Every raw scene must survive hardening
        XCTAssertEqual(
            snapshot.scenesById.count, rawManifest.scenes.count,
            "Hardened snapshot dropped \(rawManifest.scenes.count - snapshot.scenesById.count) scene(s) from library.json"
        )

        for scene in rawManifest.scenes {
            XCTAssertNotNil(
                snapshot.scene(byId: scene.id),
                "Scene '\(scene.id)' declared in library.json was dropped by loadability probe"
            )
        }
    }

    /// Every shipped template must reference only scenes that survive hardened library load.
    func test_shippedCatalogConsistentWithHardenedLibrary() throws {
        let catalogLoader = BundleTemplateCatalogLoader()
        let sceneLoader = BundleSceneLibraryLoader()

        let rawCatalog = try catalogLoader.loadManifest()
        let hardenedLibrary = try sceneLoader.load()

        for template in rawCatalog.templates {
            for sceneTypeId in template.sceneTypeIds {
                XCTAssertNotNil(
                    hardenedLibrary.scene(byId: sceneTypeId),
                    "Template '\(template.id)' references scene '\(sceneTypeId)' which is not loadable"
                )
            }
        }
    }

    // MARK: - Probe Injection Tests

    /// Scene with valid folder + passing probe survives.
    func test_sceneWithPassingProbeSurvives() throws {
        let loader = BundleSceneLibraryLoader(
            loadabilityProbe: { _ in /* success */ }
        )
        let snapshot = try loader.load()

        XCTAssertFalse(snapshot.scenesById.isEmpty)
    }

    /// Scene with folder but failing probe is skipped.
    func test_sceneWithFailingProbeIsSkipped() throws {
        struct ProbeFailure: Error {}

        let loader = BundleSceneLibraryLoader(
            loadabilityProbe: { _ in throw ProbeFailure() }
        )

        XCTAssertThrowsError(try loader.load()) { error in
            // All scenes fail probe → contentCorrupted
            guard let libraryError = error as? SceneLibraryError,
                  case .contentCorrupted = libraryError else {
                XCTFail("Expected SceneLibraryError.contentCorrupted, got \(error)")
                return
            }
        }
    }

    /// When all scenes fail probe, loader throws contentCorrupted.
    func test_allScenesFailingProbeThrowsContentCorrupted() throws {
        struct AlwaysFail: Error {}

        let loader = BundleSceneLibraryLoader(
            loadabilityProbe: { _ in throw AlwaysFail() }
        )

        XCTAssertThrowsError(try loader.load()) { error in
            guard let libraryError = error as? SceneLibraryError,
                  case .contentCorrupted(let message) = libraryError else {
                XCTFail("Expected SceneLibraryError.contentCorrupted, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("loadable"), "Error message should mention loadability: \(message)")
        }
    }

    /// Probe is called for every scene folder resolved from library.json.
    func test_probeIsCalledForEveryResolvedScene() throws {
        var probedURLs: [URL] = []

        let loader = BundleSceneLibraryLoader(
            loadabilityProbe: { url in
                probedURLs.append(url)
            }
        )

        let snapshot = try loader.load()

        XCTAssertEqual(
            probedURLs.count, snapshot.scenesById.count,
            "Probe must be called once per resolved scene"
        )
        for url in probedURLs {
            XCTAssertTrue(
                url.lastPathComponent.count > 0,
                "Probed URL must point to a real scene folder"
            )
        }
    }
}
