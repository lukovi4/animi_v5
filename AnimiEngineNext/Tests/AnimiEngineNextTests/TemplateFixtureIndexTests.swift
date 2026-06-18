import XCTest
import AnimiEngineTestSupport

/// Real-template fixture-index tests (Task-001 acceptance #6, #7, correction #4).
///
/// The real `SceneSources/` tree is read-only input. Mutation-based assertions (symlink/dotfile)
/// operate on a **temp copy** via `CopiedFixture`; `SceneSources/` is never written to.
final class TemplateFixtureIndexTests: XCTestCase {

    /// Resolves the repository root from this test file's location (test-only `#file` use —
    /// production logic always takes an injected `TemplateRepositoryRoot`).
    ///
    /// `#file` = `<repo>/AnimiEngineNext/Tests/AnimiEngineNextTests/TemplateFixtureIndexTests.swift`
    /// → four `deletingLastPathComponent` calls reach `<repo>`.
    private func repositoryRoot() -> TemplateRepositoryRoot {
        var url = URL(fileURLWithPath: #file)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return TemplateRepositoryRoot(url: url)
    }

    func testAllFiveMandatoryTemplatesResolveAndHash() throws {
        let index = TemplateFixtureIndex()
        let entries = try index.indexMandatoryTemplates(root: repositoryRoot())

        XCTAssertEqual(
            entries.map(\.catalogID),
            TemplateFixtureIndex.mandatoryCatalogIDs
        )
        for entry in entries {
            XCTAssertFalse(entry.contentHashHex.isEmpty, "\(entry.catalogID) hash empty")
            XCTAssertEqual(entry.contentHashHex.count, 64, "SHA-256 hex must be 64 chars")
        }
    }

    func testHashesAreStableAcrossRuns() throws {
        let root = repositoryRoot()
        let first = try TemplateFixtureIndex().indexMandatoryTemplates(root: root)
        let second = try TemplateFixtureIndex().indexMandatoryTemplates(root: root)
        XCTAssertEqual(first.map(\.contentHashHex), second.map(\.contentHashHex))
    }

    func testCapturesSceneIDMetadataWithoutTreatingItAsCanonicalKey() throws {
        let entries = try TemplateFixtureIndex().indexMandatoryTemplates(root: repositoryRoot())
        let fourBlocks = try XCTUnwrap(entries.first { $0.catalogID == "example_4blocks" })
        // Canonical key is the catalog directory id, not the internal sceneId.
        XCTAssertEqual(fourBlocks.catalogID, "example_4blocks")
        XCTAssertEqual(fourBlocks.sceneIDMetadata, "scene_test_2x2_4blocks")
    }

    func testMissingTemplateThrowsTypedError() throws {
        let index = TemplateFixtureIndex()
        let missing = repositoryRoot().templateDirectoryURL(forCatalogID: "does_not_exist")
        XCTAssertThrowsError(try index.indexTemplate(catalogID: "does_not_exist", directoryURL: missing)) { error in
            guard case .templateNotFound? = error as? TemplateFixtureIndex.IndexError else {
                return XCTFail("expected templateNotFound, got \(error)")
            }
        }
    }

    // MARK: - Mutation-based tests on a COPIED fixture (SceneSources/ never touched)

    func testPlantedSymlinkInCopiedFixtureIsRejected() throws {
        let fixture = try CopiedFixture(catalogID: "full_image", from: repositoryRoot())
        defer { fixture.remove() }

        try fixture.plantSymlink(named: "link.json", pointingTo: fixture.templateURL.appendingPathComponent("scene.json"))

        let index = TemplateFixtureIndex()
        XCTAssertThrowsError(try index.contentHashHex(ofTemplateAt: fixture.templateURL)) { error in
            guard case .symlinkRejected? = error as? TemplateFixtureIndex.IndexError else {
                return XCTFail("expected symlinkRejected, got \(error)")
            }
        }
    }

    func testPlantedDotfileInCopiedFixtureIsIgnored() throws {
        let root = repositoryRoot()

        // Baseline hash from a clean copy.
        let clean = try CopiedFixture(catalogID: "full_image", from: root)
        defer { clean.remove() }
        let cleanHash = try TemplateFixtureIndex().contentHashHex(ofTemplateAt: clean.templateURL)

        // Same fixture with a planted dotfile — hash must be unchanged (dotfile ignored).
        let dirty = try CopiedFixture(catalogID: "full_image", from: root)
        defer { dirty.remove() }
        try dirty.plantDotfile(named: ".DS_Store")
        let dirtyHash = try TemplateFixtureIndex().contentHashHex(ofTemplateAt: dirty.templateURL)

        XCTAssertEqual(cleanHash, dirtyHash, "dotfile must not affect the content hash")

        // SceneSources/ itself was never written to (only temp copies were mutated).
        let realDotfile = root.templateDirectoryURL(forCatalogID: "full_image")
            .appendingPathComponent(".DS_Store")
        XCTAssertFalse(FileManager.default.fileExists(atPath: realDotfile.path))
    }
}
