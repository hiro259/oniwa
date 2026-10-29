import XCTest
@testable import ONIWACore

final class SpaceNavigationTests: XCTestCase {
    func testImmediateRightAndLeftNeighbor() throws {
        XCTAssertEqual(
            try SpaceNavigation.nextStep(orderedSpaceIDs: [10, 20, 30],
                                         current: 10, target: 30),
            .move(.right, nextSpaceID: 20)
        )
        XCTAssertEqual(
            try SpaceNavigation.nextStep(orderedSpaceIDs: [10, 20, 30],
                                         current: 30, target: 10),
            .move(.left, nextSpaceID: 20)
        )
    }

    func testAlreadyAtDestination() throws {
        XCTAssertEqual(
            try SpaceNavigation.nextStep(orderedSpaceIDs: [10, 20, 30],
                                         current: 20, target: 20),
            .arrived
        )
    }

    func testRecalculatesAfterConfirmedMove() throws {
        let layout: [UInt64] = [10, 20, 30, 40]
        XCTAssertEqual(try SpaceNavigation.nextStep(orderedSpaceIDs: layout,
                                                    current: 10, target: 40),
                       .move(.right, nextSpaceID: 20))
        XCTAssertEqual(try SpaceNavigation.nextStep(orderedSpaceIDs: layout,
                                                    current: 20, target: 40),
                       .move(.right, nextSpaceID: 30))
        XCTAssertEqual(try SpaceNavigation.nextStep(orderedSpaceIDs: layout,
                                                    current: 40, target: 40),
                       .arrived)
    }

    func testRejectsStaleIDsAndDuplicateLayout() {
        XCTAssertThrowsError(try SpaceNavigation.nextStep(
            orderedSpaceIDs: [1, 2, 3], current: 99, target: 3)) {
                XCTAssertEqual($0 as? SpaceNavigation.PlanError, .currentSpaceMissing)
            }
        XCTAssertThrowsError(try SpaceNavigation.nextStep(
            orderedSpaceIDs: [1, 2, 3], current: 1, target: 99)) {
                XCTAssertEqual($0 as? SpaceNavigation.PlanError, .targetSpaceMissing)
            }
        XCTAssertThrowsError(try SpaceNavigation.nextStep(
            orderedSpaceIDs: [1, 2, 2], current: 1, target: 2)) {
                XCTAssertEqual($0 as? SpaceNavigation.PlanError, .duplicateSpaceIDs)
            }
    }

    func testEmptyLayoutIsNotSuccess() {
        XCTAssertThrowsError(try SpaceNavigation.nextStep(
            orderedSpaceIDs: [], current: 1, target: 1)) {
                XCTAssertEqual($0 as? SpaceNavigation.PlanError, .emptyLayout)
            }
    }
}
