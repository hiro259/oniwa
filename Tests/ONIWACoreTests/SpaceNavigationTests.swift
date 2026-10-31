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

    func testTrelloCaseReplansAfterMacOSReordersSpaces() throws {
        // Captured from the user's Mac: the original route to Trello crossed
        // ONIWA, main and Desktop 1, then macOS swapped ONIWA and main.
        let before: [UInt64] = [3085, 3082, 3079, 1, 3076, 3121, 2986, 3128]
        let after: [UInt64] = [3085, 3082, 3079, 1, 3121, 3076, 2986, 3128]
        XCTAssertEqual(SpaceNavigation.layoutChange(from: before, to: after),
                       .reordered)
        XCTAssertEqual(
            try SpaceNavigation.nextStep(
                orderedSpaceIDs: before, current: 2986, target: 3085),
            .move(.left, nextSpaceID: 3121))
        XCTAssertEqual(
            try SpaceNavigation.nextStep(
                orderedSpaceIDs: after, current: 1, target: 3085),
            .move(.left, nextSpaceID: 3079))
        XCTAssertEqual(
            try SpaceNavigation.nextStep(
                orderedSpaceIDs: after, current: 3079, target: 3085),
            .move(.left, nextSpaceID: 3082))
        XCTAssertEqual(
            try SpaceNavigation.nextStep(
                orderedSpaceIDs: after, current: 3082, target: 3085),
            .move(.left, nextSpaceID: 3085))
        XCTAssertEqual(
            try SpaceNavigation.nextStep(
                orderedSpaceIDs: after, current: 3085, target: 3085),
            .arrived)
    }

    func testSafeReorderRequiresExactlySameUniqueSpaceIDs() {
        XCTAssertEqual(
            SpaceNavigation.layoutChange(from: [1, 2, 3], to: [1, 2, 3]),
            .unchanged)
        XCTAssertEqual(
            SpaceNavigation.layoutChange(from: [1, 2, 3], to: [1, 3, 2]),
            .reordered)
        XCTAssertEqual(
            SpaceNavigation.layoutChange(from: [1, 2, 3], to: [1, 2]),
            .membershipChanged)
        XCTAssertEqual(
            SpaceNavigation.layoutChange(from: [1, 2, 3], to: [1, 2, 4]),
            .membershipChanged)
        XCTAssertEqual(
            SpaceNavigation.layoutChange(from: [1, 2, 3], to: [1, 2, 2]),
            .membershipChanged)
        XCTAssertEqual(
            SpaceNavigation.layoutChange(from: [1, 2, 2], to: [2, 1, 2]),
            .membershipChanged)
        XCTAssertEqual(
            SpaceNavigation.layoutChange(from: [], to: []),
            .membershipChanged)
    }

    func testEmptyLayoutIsNotSuccess() {
        XCTAssertThrowsError(try SpaceNavigation.nextStep(
            orderedSpaceIDs: [], current: 1, target: 1)) {
                XCTAssertEqual($0 as? SpaceNavigation.PlanError, .emptyLayout)
            }
    }
}
