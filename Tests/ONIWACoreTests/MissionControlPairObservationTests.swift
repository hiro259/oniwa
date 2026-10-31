import XCTest
@testable import ONIWACore

final class MissionControlPairObservationTests: XCTestCase {
    func testOverlayIDsOnBothDisplaysAreProvisional() {
        let overlay = ["internal": UInt64(1), "external": 3525]
        XCTAssertEqual(MissionControlPairObservation.arrival(
            firstDisplay: "internal", firstTarget: 3128,
            secondDisplay: "external", secondTarget: 3125,
            current: overlay), .waiting)
        let arrived = ["internal": UInt64(3128), "external": 3125]
        XCTAssertEqual(MissionControlPairObservation.arrival(
            firstDisplay: "internal", firstTarget: 3128,
            secondDisplay: "external", secondTarget: 3125,
            current: arrived), .arrived)
        XCTAssertEqual(MissionControlPairObservation.settled(
            firstDisplay: "internal", firstTarget: 3128,
            secondDisplay: "external", secondTarget: 3125,
            untouched: [:], current: arrived), .confirmed)
    }

    func testPartialClickNeverConfirmsThePair() {
        XCTAssertEqual(MissionControlPairObservation.settled(
            firstDisplay: "internal", firstTarget: 3128,
            secondDisplay: "external", secondTarget: 3125,
            untouched: [:],
            current: ["internal": 3128, "external": 3525]), .incorrectTarget)
    }

    func testUnrelatedMonitorChangeNeverPassesAfterSettling() {
        XCTAssertEqual(MissionControlPairObservation.settled(
            firstDisplay: "internal", firstTarget: 3128,
            secondDisplay: "external", secondTarget: 3125,
            untouched: ["sidecar": 90],
            current: ["internal": 3128, "external": 3125, "sidecar": 91]),
            .unrelatedDisplayChanged)
    }

    func testDisconnectedMonitorAndDuplicateDisplayIDsDoNotConfirm() {
        XCTAssertEqual(MissionControlPairObservation.settled(
            firstDisplay: "internal", firstTarget: 3128,
            secondDisplay: "external", secondTarget: 3125,
            untouched: [:], current: ["internal": 3128]), .displayUnavailable)
        XCTAssertEqual(MissionControlPairObservation.arrival(
            firstDisplay: "internal", firstTarget: 3128,
            secondDisplay: "internal", secondTarget: 3125,
            current: ["internal": 3128]), .waiting)
    }
}
