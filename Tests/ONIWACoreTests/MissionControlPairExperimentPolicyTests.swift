import XCTest
@testable import ONIWACore

final class MissionControlPairExperimentPolicyTests: XCTestCase {
    private let original: [String: UInt64] = [
        "internal": 1, "external": 10, "third": 90
    ]
    private let targets: [String: UInt64] = [
        "internal": 2, "external": 20
    ]

    private func decision(
        _ first: [String: UInt64],
        _ second: [String: UInt64],
        rosterStable: Bool = true,
        closed: Bool = true
    ) -> MissionControlPairExperimentPolicy.Decision {
        MissionControlPairExperimentPolicy.decide(
            firstDisplay: "internal", secondDisplay: "external",
            before: original, targets: targets,
            firstSample: first, secondSample: second,
            rosterStable: rosterStable, missionControlClosed: closed
        )
    }

    func testBothAXPressesArrived() {
        let final: [String: UInt64] = ["internal": 2, "external": 20, "third": 90]
        XCTAssertEqual(decision(final, final), .complete)
    }

    func testOnlyFirstMovedFallBackOnlySecond() {
        let partial: [String: UInt64] = ["internal": 2, "external": 10, "third": 90]
        XCTAssertEqual(decision(partial, partial), .keyboard(["external"]))
    }

    func testOnlySecondMovedFallBackOnlyFirst() {
        let partial: [String: UInt64] = ["internal": 1, "external": 20, "third": 90]
        XCTAssertEqual(decision(partial, partial), .keyboard(["internal"]))
    }

    func testNeitherMovedFallBackBoth() {
        XCTAssertEqual(decision(original, original), .keyboard(["internal", "external"]))
    }

    func testAlreadyAtTargetNeedsNoExtraMove() {
        let preexisting: [String: UInt64] = ["internal": 2, "external": 10, "third": 90]
        let final: [String: UInt64] = ["internal": 2, "external": 20, "third": 90]
        XCTAssertEqual(MissionControlPairExperimentPolicy.decide(
            firstDisplay: "internal", secondDisplay: "external",
            before: preexisting, targets: targets,
            firstSample: final, secondSample: final,
            rosterStable: true, missionControlClosed: true), .complete)
    }

    func testChangingOrUnexpectedStatesAreUnsafe() {
        let partial: [String: UInt64] = ["internal": 2, "external": 10, "third": 90]
        let changed: [String: UInt64] = ["internal": 2, "external": 20, "third": 90]
        XCTAssertEqual(decision(partial, changed), .abort)
        let wrong: [String: UInt64] = ["internal": 3, "external": 10, "third": 90]
        XCTAssertEqual(decision(wrong, wrong), .abort)
        let thirdMoved: [String: UInt64] = ["internal": 2, "external": 10, "third": 91]
        XCTAssertEqual(decision(thirdMoved, thirdMoved), .abort)
    }

    func testUncertainOverlayOrRosterOrMonitorAborts() {
        XCTAssertEqual(decision(original, original, closed: false), .abort)
        XCTAssertEqual(decision(original, original, rosterStable: false), .abort)
        let disconnected: [String: UInt64] = ["internal": 1, "third": 90]
        XCTAssertEqual(decision(disconnected, disconnected), .abort)
    }

    func testDuplicateDisplayIDsAbort() {
        XCTAssertEqual(MissionControlPairExperimentPolicy.decide(
            firstDisplay: "internal", secondDisplay: "internal",
            before: original, targets: targets,
            firstSample: original, secondSample: original,
            rosterStable: true, missionControlClosed: true), .abort)
    }
}
