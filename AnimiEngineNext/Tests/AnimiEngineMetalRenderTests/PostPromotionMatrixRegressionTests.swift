import XCTest
import Foundation
import AnimiEngineCore
import AnimiEngineRenderModel
import AnimiEngineNext
import AnimiEngineMetalRender
@testable import AnimiEngineDiagnostics
import AnimiEngineTestSupport
@testable import AnimiEngineRenderTestSupport

/// Task-004 / CP2 blocker — post-promotion regression gate.
///
/// Re-renders the FULL 64-candidate matrix from LIVE code (current stacking fix) and compares each
/// candidate against the committed `AnimiEngineNext/ReferenceData` set. Unlike the Step-17 promotion
/// tests (which replay baked candidate PNGs), this drives `MatrixDriver` with a `ReferenceStore`
/// pointing at the approved root, so it proves the live renderer reproduces the approved references
/// EXACTLY (64/64 exactMatch) after the stacking fix + reference regeneration.
final class PostPromotionMatrixRegressionTests: XCTestCase {

    private func packageRoot() -> URL {
        var url = URL(fileURLWithPath: #file)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("AnimiEngineNext")
    }
    private func scenesRoot() -> URL {
        var url = URL(fileURLWithPath: #file)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("AnimiApp/Resources/Scenes")
    }
    private func config() throws -> RenderConfiguration {
        try RenderConfiguration(
            output: OutputContext(canvas: try CanvasSize(width: 1080, height: 1920), frameRate: try FrameRate(numerator: 30, denominator: 1)),
            intermediateProfile: .rgba16FloatLinear)
    }
    private func engineConfig() -> EngineConfiguration {
        EngineConfiguration(
            schemaVersion: 1, projectFrameRate: 30, preview: PreviewConfiguration(frameRateLadder: [30]),
            decoder: DecoderConfiguration(backend: "videoToolbox", poolLimit: 1),
            proxy: ProxyConfiguration(profiles: [ProxyProfile(name: "p", maxDimension: 1080)]),
            cache: CacheConfiguration(frameCacheBudgetMiB: 16, diskProxyBudgetMiB: 16),
            renderQuality: RenderQualityConfiguration(profiles: [RenderQualityProfile(name: "final", scalePercent: 100)]),
            memory: MemoryConfiguration(softLimitMiB: 64, hardLimitMiB: 128),
            export: ExportConfiguration(profiles: [ExportProfile(name: "e", frameRate: 30, bitrate: 1)]),
            diagnostics: DiagnosticsConfiguration(samplingPercent: 100, output: "ndjson"))
    }

    func testLiveMatrixIsExactMatchAgainstApprovedReferenceData() throws {
        let approvedRoot = packageRoot().appendingPathComponent("ReferenceData", isDirectory: true)
        guard FileManager.default.fileExists(atPath: approvedRoot.appendingPathComponent("approval-manifest.json").path) else {
            throw XCTSkip("no approved ReferenceData present")
        }
        let device0 = try MetalTestEnvironment.requireDevice()
        let session = try MetalRenderSession(device: device0)

        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("postpromo-\(abs(name.hashValue))")
        try? FileManager.default.removeItem(at: parent)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let run = try BenchmarkRun(
            parentDirectoryURL: parent,
            idGenerator: UUIDRunIDGenerator(),
            wallClock: SystemWallClock(),
            monotonicClock: SystemMonotonicClock())

        // Drive the live matrix WITH the approved reference store → each candidate gets a verdict.
        let store = ReferenceStore(rootURL: approvedRoot)
        let driver = MatrixDriver(
            scenesRootURL: scenesRoot(), referenceStore: store,
            configuration: try config(), policy: .init(tolerances: .exact, diffAmplification: 4))
        let result = try driver.run(
            session: session, into: run,
            engineConfiguration: engineConfig(),
            deviceInfo: DeviceInfo(model: "M2Pro", systemName: "macOS", systemVersion: "test"))

        XCTAssertEqual(result.candidateCount, 64, "exactly 64 candidates rendered")

        var exact = 0
        var nonExact: [String] = []
        for (_, manifest) in result.groupManifests {
            for entry in manifest.candidates {
                if entry.verdict == "exactMatch" { exact += 1 }
                else { nonExact.append("\(entry.candidateID)=\(entry.verdict)") }
            }
        }
        XCTAssertTrue(nonExact.isEmpty, "all candidates exactMatch; non-exact: \(nonExact)")
        XCTAssertEqual(exact, 64, "64/64 exactMatch against approved ReferenceData")
        print("POST-PROMOTION-MATRIX exactMatch=\(exact)/64")
    }
}
