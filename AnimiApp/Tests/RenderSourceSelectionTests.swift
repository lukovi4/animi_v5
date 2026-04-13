import XCTest
@testable import AnimiApp
@testable import TVECore

/// Tests that render source payloads preserve their data correctly
/// for both timeline and sceneEdit modes.
final class RenderSourceSelectionTests: XCTestCase {

    // MARK: - Timeline Payload

    func test_timelinePayload_preservesResolvedFrame() {
        let commands = [RenderCommand]()
        let canvasSize = SizeD(width: 1080, height: 1920)
        let pathRegistry = PathRegistry()
        let textureProvider = InMemoryTextureProvider()
        let assetSizes: [String: AssetSize] = [:]
        let instanceId = UUID()

        let context = SceneRenderContext(
            commands: commands,
            textureProvider: textureProvider,
            pathRegistry: pathRegistry,
            assetSizes: assetSizes,
            localFrame: 42,
            canvasSize: canvasSize,
            sceneInstanceId: instanceId
        )

        let resolved = ResolvedTimelineFrame.single(context)

        let payload = TimelineRenderSourcePayload(
            resolvedFrame: resolved,
            backgroundState: nil,
            backgroundTextureProvider: nil,
            diagnosticFrameTag: 100
        )

        // Verify payload preserves frame
        if case .single(let ctx) = payload.resolvedFrame {
            XCTAssertEqual(ctx.localFrame, 42)
            XCTAssertEqual(ctx.sceneInstanceId, instanceId)
            XCTAssertEqual(ctx.canvasSize.width, 1080)
        } else {
            XCTFail("Expected .single resolved frame")
        }

        XCTAssertEqual(payload.diagnosticFrameTag, 100)
        XCTAssertNil(payload.backgroundState)
    }

    func test_timelinePayload_wrapsInRenderSource() {
        let context = SceneRenderContext(
            commands: [],
            textureProvider: InMemoryTextureProvider(),
            pathRegistry: PathRegistry(),
            assetSizes: [:],
            localFrame: 0,
            canvasSize: SizeD(width: 100, height: 100),
            sceneInstanceId: UUID()
        )

        let payload = TimelineRenderSourcePayload(
            resolvedFrame: .single(context),
            backgroundState: nil,
            backgroundTextureProvider: nil,
            diagnosticFrameTag: nil
        )

        let source = EditorRuntimeRenderSource.timeline(payload)
        if case .timeline(let p) = source {
            XCTAssertNil(p.diagnosticFrameTag)
        } else {
            XCTFail("Expected .timeline render source")
        }
    }

    // MARK: - Scene Edit Payload

    func test_sceneEditPayload_preservesCommands() {
        let provider = InMemoryTextureProvider()
        let pathRegistry = PathRegistry()
        let canvasSize = SizeD(width: 1080, height: 1920)

        let payload = SceneEditRenderSourcePayload(
            commands: [],
            textureProvider: provider,
            pathRegistry: pathRegistry,
            assetSizes: ["block1": AssetSize(width: 100, height: 200)],
            canvasSize: canvasSize,
            backgroundState: nil,
            backgroundTextureProvider: nil
        )

        XCTAssertTrue(payload.commands.isEmpty)
        XCTAssertEqual(payload.canvasSize.width, 1080)
        XCTAssertEqual(payload.canvasSize.height, 1920)
        XCTAssertEqual(payload.assetSizes.count, 1)
    }

    func test_sceneEditPayload_wrapsInRenderSource() {
        let payload = SceneEditRenderSourcePayload(
            commands: [],
            textureProvider: InMemoryTextureProvider(),
            pathRegistry: PathRegistry(),
            assetSizes: [:],
            canvasSize: SizeD(width: 100, height: 100),
            backgroundState: nil,
            backgroundTextureProvider: nil
        )

        let source = EditorRuntimeRenderSource.sceneEdit(payload)
        if case .sceneEdit(let p) = source {
            XCTAssertTrue(p.commands.isEmpty)
        } else {
            XCTFail("Expected .sceneEdit render source")
        }
    }

    // MARK: - None

    func test_noneRenderSource() {
        let source = EditorRuntimeRenderSource.none
        if case .none = source {
            // pass
        } else {
            XCTFail("Expected .none")
        }
    }
}
