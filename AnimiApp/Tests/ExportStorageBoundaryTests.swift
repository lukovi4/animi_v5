import XCTest
import TVECore
@testable import AnimiApp

/// PR5 Phase G §9.7: Proves that `ExportMediaSnapshot.build(...)` resolves
/// media **exclusively** through the injected `ProjectMediaLocator`, passing
/// the registry snapshot explicitly, and never touches a raw `ProjectStore`.
///
/// Uses a spy locator that:
/// - Counts every `absoluteURL(for:registry:)` call.
/// - Records the exact `ProjectAssetRegistry` snapshot it was given.
/// - Records which `assetId`s were requested.
///
/// This is the behavioral guarantee Phase D's blocker fix enforces for
/// production export. Any accidental regression that reintroduces raw
/// `ProjectStore()` / deprecated `absoluteURL(for:)` calls inside the export
/// path would break these tests.
@MainActor
final class ExportStorageBoundaryTests: XCTestCase {

    // MARK: - Spy Locator

    final class SpyLocator: ProjectMediaLocator, @unchecked Sendable {
        private let realProjectsDir: URL

        private(set) var callCount: Int = 0
        private(set) var requestedAssetIds: [ProjectAssetID] = []
        private(set) var lastRegistry: ProjectAssetRegistry?
        private(set) var registryDescriptorHitCount: Int = 0

        init(projectsDir: URL) {
            self.realProjectsDir = projectsDir
        }

        func absoluteURL(for mediaRef: MediaRef, registry: ProjectAssetRegistry) async throws -> URL {
            callCount += 1
            requestedAssetIds.append(mediaRef.assetId)
            lastRegistry = registry
            // Register a "hit" if the registry actually contains this asset —
            // this is the contract we want exports to use in production.
            if registry.descriptor(for: mediaRef.assetId) != nil {
                registryDescriptorHitCount += 1
            }
            // Resolve via storagePath so the file-exists check inside
            // `ExportMediaSnapshot.build` can succeed for test fixtures.
            return realProjectsDir.appendingPathComponent(mediaRef.storagePath)
        }
    }

    // MARK: - Scaffolding

    private func makeMinimalRuntime() -> (CompiledScene, SceneRuntime) {
        let canvas = Canvas(width: 1080, height: 1920, fps: 30, durationFrames: 100)
        let scene = Scene(
            schemaVersion: "1.0",
            sceneId: "test",
            canvas: canvas,
            background: nil,
            mediaBlocks: []
        )
        let runtime = SceneRuntime(
            scene: scene,
            canvas: canvas,
            blocks: [],
            durationFrames: 100,
            fps: 30
        )
        let compiled = CompiledScene(
            runtime: runtime,
            mergedAssetIndex: AssetIndexIR(),
            pathRegistry: PathRegistry(),
            bindingAssetIds: []
        )
        return (compiled, runtime)
    }

    /// Writes a trivial JPEG to disk so `FileManager.default.fileExists(atPath:)`
    /// inside `ExportMediaSnapshot.build` passes.
    private func writeStubPhoto(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Minimum viable JPEG marker — enough for file-exists check; we don't
        // actually open the file in these tests.
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: url)
    }

    // MARK: - Tests

    /// `ExportMediaSnapshot.build` routes every photo slot through the
    /// injected locator exactly once, using the supplied registry snapshot.
    func test_exportMediaSnapshot_usesOnlyInjectedLocator() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pr5_phaseG_export_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Seed a real file the spy can point to.
        let relativePath = "Media/UserMedia/photo.jpg"
        try writeStubPhoto(at: tempDir.appendingPathComponent(relativePath))

        let (compiled, runtime) = makeMinimalRuntime()

        // Build a registry populated with the descriptor. The spy will
        // observe that `registry.descriptor(for: assetId) != nil`.
        let assetId = ProjectAssetID()
        var registry = ProjectAssetRegistry()
        registry.register(ProjectAssetDescriptor(
            assetId: assetId,
            mediaKind: .photo,
            storagePath: relativePath
        ))

        let mediaRef = MediaRef(storagePath: relativePath, mediaKind: .photo, assetId: assetId)
        let mediaSlots: [String: SceneMediaSlot] = [
            "block1": .photo(mediaRef: mediaRef, placement: .defaultCover)
        ]

        let spy = SpyLocator(projectsDir: tempDir)

        let snapshot = try await ExportMediaSnapshot.build(
            compiledScene: compiled,
            mediaSlots: mediaSlots,
            mediaLocator: spy,
            assetRegistry: registry,
            runtime: runtime
        )

        // Spy contract:
        // - Called exactly once (one visible photo slot).
        XCTAssertEqual(spy.callCount, 1, "Spy must receive exactly one resolution call")
        // - Requested the slot's assetId.
        XCTAssertEqual(spy.requestedAssetIds, [assetId], "Spy must be asked for the slot's assetId")
        // - Received the populated registry snapshot.
        XCTAssertNotNil(spy.lastRegistry)
        XCTAssertNotNil(
            spy.lastRegistry?.descriptor(for: assetId),
            "The registry snapshot passed to the spy must contain the descriptor"
        )
        // - Registry descriptor was the resolution path (production contract).
        XCTAssertEqual(
            spy.registryDescriptorHitCount,
            1,
            "Export must resolve through the registry descriptor, not a legacy fallback"
        )

        // Sanity: snapshot contains exactly one image ref.
        XCTAssertEqual(snapshot.imageRefs.count, 1)
    }

    /// Spy returns URLs unrelated to `ProjectStore`; the snapshot build must
    /// still succeed, proving it does not cross-check against a real store.
    func test_exportMediaSnapshot_doesNotFallBackToProjectStore() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pr5_phaseG_export_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let relativePath = "Media/UserMedia/isolated.jpg"
        try writeStubPhoto(at: tempDir.appendingPathComponent(relativePath))

        let (compiled, runtime) = makeMinimalRuntime()

        let assetId = ProjectAssetID()
        var registry = ProjectAssetRegistry()
        registry.register(ProjectAssetDescriptor(
            assetId: assetId,
            mediaKind: .photo,
            storagePath: relativePath
        ))

        let mediaSlots: [String: SceneMediaSlot] = [
            "block1": .photo(
                mediaRef: MediaRef(storagePath: relativePath, mediaKind: .photo, assetId: assetId),
                placement: .defaultCover
            )
        ]

        let spy = SpyLocator(projectsDir: tempDir)

        let snapshot = try await ExportMediaSnapshot.build(
            compiledScene: compiled,
            mediaSlots: mediaSlots,
            mediaLocator: spy,
            assetRegistry: registry,
            runtime: runtime
        )

        // The snapshot's resolved URL must be the spy-provided URL (rooted at
        // tempDir), not a URL under the real Application Support projects dir.
        let resolvedURL = try XCTUnwrap(snapshot.imageRefs.first?.url)
        XCTAssertTrue(
            resolvedURL.path.hasPrefix(tempDir.path),
            "Resolved URL must come from the spy locator, not a raw ProjectStore — got \(resolvedURL.path)"
        )
    }

    /// Hidden slots are excluded from the snapshot and must not ping the
    /// locator at all.
    func test_exportMediaSnapshot_hiddenSlotDoesNotTouchLocator() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pr5_phaseG_export_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (compiled, runtime) = makeMinimalRuntime()

        let assetId = ProjectAssetID()
        let mediaSlots: [String: SceneMediaSlot] = [
            "block1": .photo(
                mediaRef: MediaRef(storagePath: "Media/UserMedia/hidden.jpg", mediaKind: .photo, assetId: assetId),
                visibility: false,
                placement: .defaultCover
            )
        ]

        let spy = SpyLocator(projectsDir: tempDir)

        let snapshot = try await ExportMediaSnapshot.build(
            compiledScene: compiled,
            mediaSlots: mediaSlots,
            mediaLocator: spy,
            assetRegistry: ProjectAssetRegistry(),
            runtime: runtime
        )

        XCTAssertEqual(spy.callCount, 0, "Hidden slot must not trigger locator resolution")
        XCTAssertTrue(snapshot.imageRefs.isEmpty)
        XCTAssertTrue(snapshot.videoRefs.isEmpty)
    }
}
