import XCTest
@testable import AnimiApp

/// Tests for OverlayLaneSnapshot row packing and OverlayLaneView behavior.
final class OverlayLaneTests: XCTestCase {

    // MARK: - Row Packing

    func testPackRows_empty_returnsRowCount1() {
        let (items, rowCount) = OverlayLaneSnapshot.packRows([])
        XCTAssertTrue(items.isEmpty)
        XCTAssertEqual(rowCount, 1, "Empty input should produce rowCount 1 (minimum)")
    }

    func testPackRows_nonOverlapping_singleRow() {
        let input: [(id: UUID, startUs: TimeUs, durationUs: TimeUs, label: String)] = [
            (id: UUID(), startUs: 0, durationUs: 1_000_000, label: "A"),
            (id: UUID(), startUs: 1_000_000, durationUs: 1_000_000, label: "B"),
            (id: UUID(), startUs: 2_000_000, durationUs: 1_000_000, label: "C"),
        ]
        let (items, rowCount) = OverlayLaneSnapshot.packRows(input)
        XCTAssertEqual(rowCount, 1, "Non-overlapping items should fit in a single row")
        XCTAssertTrue(items.allSatisfy { $0.row == 0 })
    }

    func testPackRows_overlapping_multipleRows() {
        let input: [(id: UUID, startUs: TimeUs, durationUs: TimeUs, label: String)] = [
            (id: UUID(), startUs: 0, durationUs: 2_000_000, label: "A"),
            (id: UUID(), startUs: 500_000, durationUs: 2_000_000, label: "B"),
            (id: UUID(), startUs: 1_000_000, durationUs: 2_000_000, label: "C"),
        ]
        let (items, rowCount) = OverlayLaneSnapshot.packRows(input)
        XCTAssertEqual(rowCount, 3, "Three overlapping items should require 3 rows")
        let rows = Set(items.map(\.row))
        XCTAssertEqual(rows, [0, 1, 2])
    }

    func testPackRows_partialOverlap_reusesRows() {
        let idA = UUID(), idB = UUID(), idC = UUID()
        let input: [(id: UUID, startUs: TimeUs, durationUs: TimeUs, label: String)] = [
            (id: idA, startUs: 0, durationUs: 2_000_000, label: "A"),         // 0-2s
            (id: idB, startUs: 1_000_000, durationUs: 1_000_000, label: "B"), // 1-2s (overlaps A)
            (id: idC, startUs: 2_000_000, durationUs: 1_000_000, label: "C"), // 2-3s (fits after A in row 0)
        ]
        let (items, rowCount) = OverlayLaneSnapshot.packRows(input)
        XCTAssertEqual(rowCount, 2, "C should reuse row 0 after A ends")

        let itemMap = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.row) })
        XCTAssertEqual(itemMap[idA], 0)
        XCTAssertEqual(itemMap[idB], 1)
        XCTAssertEqual(itemMap[idC], 0, "C should be packed into row 0 (reused from A)")
    }

    func testPackRows_unsortedInput_sortsInternally() {
        let idA = UUID(), idB = UUID(), idC = UUID()
        // Deliberately unsorted
        let input: [(id: UUID, startUs: TimeUs, durationUs: TimeUs, label: String)] = [
            (id: idC, startUs: 4_000_000, durationUs: 1_000_000, label: "C"),
            (id: idA, startUs: 0, durationUs: 1_000_000, label: "A"),
            (id: idB, startUs: 2_000_000, durationUs: 1_000_000, label: "B"),
        ]
        let (items, rowCount) = OverlayLaneSnapshot.packRows(input)
        XCTAssertEqual(rowCount, 1, "Non-overlapping items should fit in 1 row regardless of input order")
        XCTAssertTrue(items.allSatisfy { $0.row == 0 })
    }
}
