import XCTest
@testable import ONIWACore

final class SpaceEditorLayoutTests: XCTestCase {
    func testAddingFirstTagExpandsViewportToKeepAppVisible() {
        let withoutTag = SpaceEditorLayout.scrollHeight(
            tagCount: 0, appCount: 1, isSessionOnly: false,
            availableScreenHeight: 900)
        let withTag = SpaceEditorLayout.scrollHeight(
            tagCount: 1, appCount: 1, isSessionOnly: false,
            availableScreenHeight: 900)
        XCTAssertGreaterThan(withTag, withoutTag)
        XCTAssertEqual(withTag - withoutTag, 42)
        XCTAssertGreaterThanOrEqual(withTag, SpaceEditorLayout.minimumAppGridHeight)
    }

    func testMoreAppRowsIncreaseHeightUntilThreeRows() {
        func height(_ appCount: Int) -> CGFloat {
            SpaceEditorLayout.scrollHeight(tagCount: 0, appCount: appCount,
                                           isSessionOnly: false,
                                           availableScreenHeight: 900)
        }
        XCTAssertGreaterThan(height(4), height(1))
        XCTAssertGreaterThan(height(7), height(4))
        XCTAssertEqual(height(10), height(7))
    }

    func testScreenLimitCapsContentInsteadOfClippingRows() {
        let available: CGFloat = 520
        let height = SpaceEditorLayout.scrollHeight(
            tagCount: 8, appCount: 15, isSessionOnly: true,
            availableScreenHeight: available)
        XCTAssertLessThanOrEqual(height, available - 160)
        XCTAssertGreaterThanOrEqual(height, 180)
    }

    func testEmptyEditorDoesNotGrowUnnecessarily() {
        let height = SpaceEditorLayout.scrollHeight(
            tagCount: 0, appCount: 0, isSessionOnly: false,
            availableScreenHeight: 900)
        XCTAssertEqual(height, 245)
    }

    func testNoNegativeHeightWithTinyDisplayOrEmptyCounts() {
        let height = SpaceEditorLayout.scrollHeight(
            tagCount: -1, appCount: -10, isSessionOnly: false,
            availableScreenHeight: 300)
        XCTAssertGreaterThan(height, 0)
        XCTAssertLessThanOrEqual(height, 180)
    }
}
