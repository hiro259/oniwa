import XCTest
@testable import ONIWACore

final class SpaceSwitchObservationTests: XCTestCase {
    func testExpectedMoveOnlyOnTarget() {
        XCTAssertEqual(
            SpaceSwitchObservation.evaluate(
                targetDisplay: "monitor2", beforeTarget: 20, expectedTarget: 21,
                beforeOthers: ["monitor1": 10], after: ["monitor1": 10, "monitor2": 21]),
            .confirmed
        )
    }

    func testTargetNotYetMoved() {
        XCTAssertEqual(
            SpaceSwitchObservation.evaluate(
                targetDisplay: "monitor2", beforeTarget: 20, expectedTarget: 21,
                beforeOthers: ["monitor1": 10], after: ["monitor1": 10, "monitor2": 20]),
            .waiting
        )
    }

    func testWrongMonitorMovedEvenIfTargetDidNotMove() {
        XCTAssertEqual(
            SpaceSwitchObservation.evaluate(
                targetDisplay: "monitor2", beforeTarget: 20, expectedTarget: 21,
                beforeOthers: ["monitor1": 10], after: ["monitor1": 11, "monitor2": 20]),
            .otherDisplayChanged
        )
    }

    func testWrongMonitorMovedEvenIfTargetAlsoReachedExpected() {
        XCTAssertEqual(
            SpaceSwitchObservation.evaluate(
                targetDisplay: "monitor2", beforeTarget: 20, expectedTarget: 21,
                beforeOthers: ["monitor1": 10], after: ["monitor1": 11, "monitor2": 21]),
            .otherDisplayChanged
        )
    }

    func testWrongTargetSpaceNeverCountsAsSuccess() {
        XCTAssertEqual(
            SpaceSwitchObservation.evaluate(
                targetDisplay: "monitor2", beforeTarget: 20, expectedTarget: 21,
                beforeOthers: ["monitor1": 10], after: ["monitor1": 10, "monitor2": 22]),
            .wrongTarget
        )
    }

    func testMissingDisplayIsNotSuccess() {
        XCTAssertEqual(
            SpaceSwitchObservation.evaluate(
                targetDisplay: "monitor2", beforeTarget: 20, expectedTarget: 21,
                beforeOthers: ["monitor1": 10], after: ["monitor1": 10]),
            .displayUnavailable
        )
        XCTAssertEqual(
            SpaceSwitchObservation.evaluate(
                targetDisplay: "monitor2", beforeTarget: 20, expectedTarget: 21,
                beforeOthers: ["monitor1": 10], after: ["monitor2": 21]),
            .displayUnavailable
        )
    }

    func testWorksWithMultipleUnrelatedMonitors() {
        XCTAssertEqual(
            SpaceSwitchObservation.evaluate(
                targetDisplay: "monitor2", beforeTarget: 20, expectedTarget: 21,
                beforeOthers: ["monitor1": 10, "sidecar": 30],
                after: ["monitor1": 10, "monitor2": 21, "sidecar": 30]),
            .confirmed
        )
    }
}
