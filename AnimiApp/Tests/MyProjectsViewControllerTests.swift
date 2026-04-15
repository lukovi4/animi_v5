import XCTest
@testable import AnimiApp

final class MyProjectsViewControllerTests: XCTestCase {

    func testGroupByDate_equalTimestampsInSameDay_preservesInputOrder() {
        // Canonical order (as persistence would return): higher UUID first on tie.
        let sameInstant = Date()
        let higherUUID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let lowerUUID  = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

        let a = SavedProjectSummary(
            projectId: higherUUID,
            savedAt: sameInstant,
            title: "A",
            origin: .blank(starterSceneTypeId: "scene_1"),
            previewURL: nil
        )
        let b = SavedProjectSummary(
            projectId: lowerUUID,
            savedAt: sameInstant,
            title: "B",
            origin: .blank(starterSceneTypeId: "scene_1"),
            previewURL: nil
        )

        // Pass in canonical order (higher UUID first), assert groupByDate
        // does NOT re-shuffle within the section.
        let sections = MyProjectsViewController.groupByDate([a, b])

        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].title, "Today")
        XCTAssertEqual(sections[0].entries.map { $0.projectId }, [higherUUID, lowerUUID])
    }

    func testGroupByDate_multipleDays_routesToCorrectSections() {
        let calendar = Calendar.current
        let today = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let lastWeek = calendar.date(byAdding: .day, value: -7, to: today)!

        let entries = [
            SavedProjectSummary(projectId: UUID(), savedAt: today,     title: "t", origin: .blank(starterSceneTypeId: "scene_1"), previewURL: nil),
            SavedProjectSummary(projectId: UUID(), savedAt: yesterday, title: "y", origin: .blank(starterSceneTypeId: "scene_1"), previewURL: nil),
            SavedProjectSummary(projectId: UUID(), savedAt: lastWeek,  title: "e", origin: .blank(starterSceneTypeId: "scene_1"), previewURL: nil),
        ]

        let sections = MyProjectsViewController.groupByDate(entries)

        XCTAssertEqual(sections.map { $0.title }, ["Today", "Yesterday", "Earlier"])
        XCTAssertEqual(sections[0].entries.count, 1)
        XCTAssertEqual(sections[1].entries.count, 1)
        XCTAssertEqual(sections[2].entries.count, 1)
    }
}
