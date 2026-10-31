import XCTest
@testable import ONIWACore

final class SwitchModeSelectionTests: XCTestCase {
    func testEachModeGroupHasExactlyThreeUniqueOptions() {
        XCTAssertEqual(Set(SingleSpaceSwitchMode.allCases.map(\.rawValue)).count, 3)
        XCTAssertEqual(Set(PairSpaceSwitchMode.allCases.map(\.rawValue)).count, 3)
    }

    func testLegacySinglePrefersDirectMissionControlOverInstant() {
        XCTAssertEqual(SwitchModeMigration.single(instant: true, missionControl: true),
                       .missionControl)
        XCTAssertEqual(SwitchModeMigration.single(instant: true, missionControl: false),
                       .instant)
        XCTAssertEqual(SwitchModeMigration.single(instant: false, missionControl: false),
                       .keyboard)
    }

    func testLegacyPairPrefersHybridOnlyWhenMissionControlWasEnabled() {
        XCTAssertEqual(SwitchModeMigration.pair(missionControl: true, hybrid: true),
                       .hybrid)
        XCTAssertEqual(SwitchModeMigration.pair(missionControl: true, hybrid: false),
                       .missionControlTwice)
        XCTAssertEqual(SwitchModeMigration.pair(missionControl: false, hybrid: true),
                       .keyboard)
        XCTAssertEqual(SwitchModeMigration.pair(missionControl: false, hybrid: false),
                       .keyboard)
    }

    func testFailedOneSessionExperimentCannotBeSelected() {
        XCTAssertNil(PairSpaceSwitchMode(rawValue: "missionControlOnce"))
        XCTAssertNil(PairSpaceSwitchMode(rawValue: "pairSingleSession"))
    }

    func testModesRoundTripToTheirPersistedString() {
        for mode in SingleSpaceSwitchMode.allCases {
            XCTAssertEqual(SingleSpaceSwitchMode(rawValue: mode.rawValue), mode)
        }
        for mode in PairSpaceSwitchMode.allCases {
            XCTAssertEqual(PairSpaceSwitchMode(rawValue: mode.rawValue), mode)
        }
    }
}
