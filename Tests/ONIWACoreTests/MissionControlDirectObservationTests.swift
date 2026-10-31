import XCTest
@testable import ONIWACore

final class MissionControlDirectObservationTests: XCTestCase {
    func testMissionControlOverlayCanChangeBothDisplaysBeforeArrival() {
        // Real trace, 2026-10-31: opening Mission Control temporarily
        // exposed built-in=1, external=3525. The external target was 3125.
        let temporary: [String: UInt64] = ["built-in": 1, "external": 3525]
        XCTAssertEqual(
            MissionControlDirectObservation.arrival(
                targetDisplay: "external", expectedTarget: 3125, after: temporary),
            .waiting)
        let arrivedWhileOtherIsProvisional: [String: UInt64] =
            ["built-in": 1, "external": 3125]
        XCTAssertEqual(
            MissionControlDirectObservation.arrival(
                targetDisplay: "external", expectedTarget: 3125,
                after: arrivedWhileOtherIsProvisional),
            .arrived)
        let settled: [String: UInt64] = ["built-in": 3128, "external": 3125]
        XCTAssertEqual(
            MissionControlDirectObservation.settled(
                targetDisplay: "external", expectedTarget: 3125,
                beforeOthers: ["built-in": 3128], after: settled),
            .confirmed)
    }

    func testTargetMayTemporarilyChangeToOverlaySpaceBeforeCorrectArrival() {
        XCTAssertEqual(
            MissionControlDirectObservation.arrival(
                targetDisplay: "built-in", expectedTarget: 3121,
                after: ["built-in": 1, "external": 3525]),
            .waiting)
        XCTAssertEqual(
            MissionControlDirectObservation.arrival(
                targetDisplay: "built-in", expectedTarget: 3121,
                after: ["built-in": 3121, "external": 2976]),
            .arrived)
    }

    func testPermanentOtherDisplayChangeIsNeverReportedAsSuccess() {
        XCTAssertEqual(
            MissionControlDirectObservation.settled(
                targetDisplay: "external", expectedTarget: 3125,
                beforeOthers: ["built-in": 3128],
                after: ["built-in": 1, "external": 3125]),
            .otherDisplayChanged)
    }

    func testUnexpectedTargetCannotPassSettledVerification() {
        XCTAssertEqual(
            MissionControlDirectObservation.settled(
                targetDisplay: "external", expectedTarget: 3125,
                beforeOthers: ["built-in": 3128],
                after: ["built-in": 3128, "external": 3739]),
            .wrongTarget)
    }

    func testDisconnectOrMissingDisplayCannotPassSettledVerification() {
        XCTAssertEqual(
            MissionControlDirectObservation.arrival(
                targetDisplay: "external", expectedTarget: 3125,
                after: ["built-in": 3128]),
            .displayUnavailable)
        XCTAssertEqual(
            MissionControlDirectObservation.settled(
                targetDisplay: "external", expectedTarget: 3125,
                beforeOthers: ["built-in": 3128],
                after: ["external": 3125]),
            .displayUnavailable)
    }

    func testThirdDisplayMustAlsoRemainAtOriginalSpaceAfterSettling() {
        XCTAssertEqual(
            MissionControlDirectObservation.settled(
                targetDisplay: "built-in", expectedTarget: 3121,
                beforeOthers: ["external": 2976, "sidecar": 90],
                after: ["built-in": 3121, "external": 2976, "sidecar": 91]),
            .otherDisplayChanged)
    }
}
