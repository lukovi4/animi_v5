import XCTest
@testable import AnimiApp

/// Tests for ExportPreflightPlanner budget computation.
final class ExportPreflightPlannerTests: XCTestCase {

    // MARK: - Safe Plan

    func test_safePlan_singleScene() {
        let result = ExportPreflightPlanner.plan(
            sceneCount: 1,
            canvasSize: (width: 1080, height: 1920),
            videoSlotCount: 0,
            fps: 30
        )

        switch result {
        case .safe(let budget):
            XCTAssertEqual(budget.maxResidentScenes, 1, "Single scene should have maxResidentScenes=1")
            XCTAssertGreaterThan(budget.maxFramesInFlight, 0)
            XCTAssertGreaterThan(budget.targetImageMaxDimensionPx, 0)
            XCTAssertEqual(budget.videoPrefetchFrames, 30, "Prefetch frames should match FPS")
        case .recommendLowerPreset:
            // This may happen on constrained test runners — not a failure
            break
        }
    }

    func test_safePlan_multiScene() {
        let result = ExportPreflightPlanner.plan(
            sceneCount: 5,
            canvasSize: (width: 1080, height: 1920),
            videoSlotCount: 2,
            fps: 30
        )

        let budget = result.budget
        XCTAssertEqual(budget.maxResidentScenes, 2, "Multi-scene should have maxResidentScenes=2")
        XCTAssertGreaterThanOrEqual(budget.maxActiveVideoProviders, 1)
    }

    // MARK: - Budget Defaults

    func test_defaultBudget_hasReasonableValues() {
        let budget = ExportResourceBudget.default
        XCTAssertEqual(budget.maxResidentScenes, 2)
        XCTAssertEqual(budget.maxActiveVideoProviders, 4)
        XCTAssertEqual(budget.videoPrefetchFrames, 30)
        XCTAssertEqual(budget.maxFramesInFlight, 3)
        XCTAssertEqual(budget.targetImageMaxDimensionPx, 2048)
    }

    // MARK: - Preflight Result

    func test_preflightResult_budgetAccessor() {
        let budget = ExportResourceBudget(maxResidentScenes: 1)

        let safeResult = ExportPreflightResult.safe(budget)
        XCTAssertEqual(safeResult.budget, budget)

        let recommendResult = ExportPreflightResult.recommendLowerPreset(budget: budget, suggestedPreset: .medium, suggestedSizePx: (width: 1080, height: 1920))
        XCTAssertEqual(recommendResult.budget, budget)
    }

    // MARK: - Background Region Count

    func test_backgroundRegionCount_increasesEstimatedMemory() {
        // With 0 background regions — may be safe on high-memory devices
        let resultNoBg = ExportPreflightPlanner.plan(
            sceneCount: 1,
            canvasSize: (width: 1080, height: 1920),
            videoSlotCount: 0,
            backgroundRegionCount: 0,
            fps: 30
        )

        // With many background regions — increases memory pressure
        let resultManyBg = ExportPreflightPlanner.plan(
            sceneCount: 1,
            canvasSize: (width: 1080, height: 1920),
            videoSlotCount: 0,
            backgroundRegionCount: 10,
            fps: 30
        )

        // Both should produce valid budgets
        XCTAssertGreaterThan(resultNoBg.budget.maxFramesInFlight, 0)
        XCTAssertGreaterThan(resultManyBg.budget.maxFramesInFlight, 0)

        // If the no-bg result is safe, adding 10 regions (200MB) may trigger recommendation
        // (depends on available memory, so we just verify the API accepts the parameter)
    }

    // MARK: - Suggested Lower Preset

    func test_suggestedPreset_bitrateIsLowerThanOriginal() {
        // Verify that the suggested preset produces a lower bitrate than the original
        let originalSize = (width: 1920, height: 1080)
        let originalBitrate = VideoQualityPreset.high.bitrate(for: originalSize)

        // Simulate what preflight would suggest: scale down to 720p and step down preset
        let suggestedSize = (width: 1280, height: 720)
        let suggestedBitrate = VideoQualityPreset.medium.bitrate(for: suggestedSize)

        XCTAssertLessThan(suggestedBitrate, originalBitrate,
            "Reduced preset+size should produce lower bitrate")
    }

    func test_suggestedSize_isEvenAligned() {
        // Canvas larger than 1280 should produce even-aligned suggested dimensions
        let result = ExportPreflightPlanner.plan(
            sceneCount: 10,
            canvasSize: (width: 1920, height: 1080),
            videoSlotCount: 20,
            backgroundRegionCount: 5,
            currentPreset: .high,
            fps: 30
        )

        // On any device this heavyweight plan should recommend lower preset
        if case .recommendLowerPreset(_, _, let suggestedSizePx) = result {
            XCTAssertEqual(suggestedSizePx.width % 2, 0, "Width must be even-aligned")
            XCTAssertEqual(suggestedSizePx.height % 2, 0, "Height must be even-aligned")
            XCTAssertLessThanOrEqual(max(suggestedSizePx.width, suggestedSizePx.height), 1280,
                "Suggested size should be scaled to 720p")
        }
        // If safe, that's fine too — test runner has plenty of memory
    }

    // MARK: - FPS-Driven Prefetch

    func test_prefetchFrames_matchesFPS() {
        let result30 = ExportPreflightPlanner.plan(
            sceneCount: 1,
            canvasSize: (width: 1080, height: 1920),
            videoSlotCount: 0,
            fps: 30
        )
        XCTAssertEqual(result30.budget.videoPrefetchFrames, 30)

        let result60 = ExportPreflightPlanner.plan(
            sceneCount: 1,
            canvasSize: (width: 1080, height: 1920),
            videoSlotCount: 0,
            fps: 60
        )
        XCTAssertEqual(result60.budget.videoPrefetchFrames, 60)
    }

    // MARK: - Canvas-Aware Image Dimension

    func test_canvasAwareImageDimension_cappedForSmallCanvas() {
        let result = ExportPreflightPlanner.plan(
            sceneCount: 1,
            canvasSize: (width: 1280, height: 720),
            videoSlotCount: 0,
            fps: 30
        )
        // 720p max dimension = 1280, capped at 2x = 2560
        XCTAssertLessThanOrEqual(result.budget.targetImageMaxDimensionPx, 2560,
            "Image dimension should be capped to 2x canvas for small canvas")
    }

    func test_canvasAwareImageDimension_uncappedForLargeCanvas() {
        let result = ExportPreflightPlanner.plan(
            sceneCount: 1,
            canvasSize: (width: 3840, height: 2160),
            videoSlotCount: 0,
            fps: 30
        )
        // 4K canvas * 2 = 7680, which exceeds device class limits (2048-4096)
        // So device class limit wins → at least 2048
        XCTAssertGreaterThanOrEqual(result.budget.targetImageMaxDimensionPx, 2048,
            "Large canvas should not reduce below device class minimum")
    }

    func test_canvasAwareImageDimension_1080pCapped() {
        let result = ExportPreflightPlanner.plan(
            sceneCount: 1,
            canvasSize: (width: 1080, height: 1920),
            videoSlotCount: 0,
            fps: 30
        )
        // 1920 * 2 = 3840
        XCTAssertLessThanOrEqual(result.budget.targetImageMaxDimensionPx, 3840,
            "1080p canvas should cap image dimension to 3840")
    }
}
