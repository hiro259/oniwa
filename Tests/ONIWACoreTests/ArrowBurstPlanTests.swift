import XCTest
@testable import ONIWACore

final class ArrowBurstPlanTests: XCTestCase {
    func testRightJumpPlansEveryIntermediateSpace() {
        XCTAssertEqual(
            ArrowBurstPlan.make(order: [10, 11, 12, 13], current: 10, target: 13),
            .burst(direction: .right, steps: 3, path: [11, 12, 13]))
    }
    func testLeftJumpSupportsFullscreenSpaceIDs() {
        XCTAssertEqual(
            ArrowBurstPlan.make(order: [10, 11, 12, 13], current: 13, target: 10),
            .burst(direction: .left, steps: 3, path: [12, 11, 10]))
    }
    func testAlreadyVisibleNeedsNoInput() {
        XCTAssertEqual(
            ArrowBurstPlan.make(order: [10, 11], current: 11, target: 11),
            .arrived)
    }
    func testInvalidPlanAbortsBeforePostingAnyKeys() {
        XCTAssertEqual(
            ArrowBurstPlan.make(order: [1, 1, 2], current: 1, target: 2),
            .blocked(reason: "invalid-space-order"))
        XCTAssertEqual(
            ArrowBurstPlan.make(order: [1, 2], current: 3, target: 2),
            .blocked(reason: "current-not-in-order"))
        XCTAssertEqual(
            ArrowBurstPlan.make(order: [1, 2], current: 1, target: 3),
            .blocked(reason: "target-not-in-order"))
        XCTAssertEqual(
            ArrowBurstPlan.make(order: Array(1...15).map(UInt64.init),
                                current: 1, target: 15),
            .blocked(reason: "step-limit"))
    }
}
