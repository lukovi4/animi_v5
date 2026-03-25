import XCTest
@testable import AnimiApp

/// Tests for ExportResourceBudget value type.
final class ExportResourceBudgetTests: XCTestCase {

    func test_equatable() {
        let a = ExportResourceBudget(maxResidentScenes: 2, targetImageMaxDimensionPx: 2048)
        let b = ExportResourceBudget(maxResidentScenes: 2, targetImageMaxDimensionPx: 2048)
        let c = ExportResourceBudget(maxResidentScenes: 1, targetImageMaxDimensionPx: 4096)

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func test_defaultValues() {
        let budget = ExportResourceBudget()
        XCTAssertEqual(budget.maxResidentScenes, 2)
        XCTAssertEqual(budget.maxActiveVideoProviders, 4)
        XCTAssertEqual(budget.videoPrefetchFrames, 30)
        XCTAssertEqual(budget.maxFramesInFlight, 3)
        XCTAssertEqual(budget.targetImageMaxDimensionPx, 2048)
    }

    func test_customValues() {
        let budget = ExportResourceBudget(
            maxResidentScenes: 1,
            maxActiveVideoProviders: 2,
            videoPrefetchFrames: 60,
            maxFramesInFlight: 2,
            targetImageMaxDimensionPx: 4096
        )
        XCTAssertEqual(budget.maxResidentScenes, 1)
        XCTAssertEqual(budget.maxActiveVideoProviders, 2)
        XCTAssertEqual(budget.videoPrefetchFrames, 60)
        XCTAssertEqual(budget.maxFramesInFlight, 2)
        XCTAssertEqual(budget.targetImageMaxDimensionPx, 4096)
    }
}
