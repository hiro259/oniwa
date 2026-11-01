import XCTest
@testable import ONIWACore

final class GlobalInstantExperimentPolicyTests: XCTestCase {
    func testGlobalOverridesEverySingleSelectionWithoutChangingIt() {
        for selected in SingleSpaceSwitchMode.allCases {
            XCTAssertEqual(GlobalInstantExperimentPolicy.singleMode(
                enabled: true, selected: selected), .instant)
            XCTAssertEqual(GlobalInstantExperimentPolicy.singleMode(
                enabled: false, selected: selected), selected)
        }
    }

    func testGlobalOverridesAllPairModesAndDisablesHybrid() {
        for pair in PairSpaceSwitchMode.allCases {
            XCTAssertEqual(GlobalInstantExperimentPolicy.pairStepMode(
                enabled: true, selected: pair, hadGestureFallback: false), .instant)
            XCTAssertFalse(GlobalInstantExperimentPolicy.usesHybrid(
                enabled: true, selected: pair))
        }
        XCTAssertTrue(GlobalInstantExperimentPolicy.usesHybrid(
            enabled: false, selected: .hybrid))
    }

    func testPairFallbackUsesKeyboardForRemainderButNotNextInvocation() {
        XCTAssertEqual(GlobalInstantExperimentPolicy.pairStepMode(
            enabled: true, selected: .hybrid, hadGestureFallback: true), .keyboard)
        // Next invocation starts with a fresh local fallback marker = false.
        XCTAssertEqual(GlobalInstantExperimentPolicy.pairStepMode(
            enabled: true, selected: .hybrid, hadGestureFallback: false), .instant)
    }

    func testNormalPairModesRemainUnchangedWhenExperimentIsOff() {
        XCTAssertEqual(GlobalInstantExperimentPolicy.pairStepMode(
            enabled: false, selected: .keyboard, hadGestureFallback: false), .keyboard)
        XCTAssertEqual(GlobalInstantExperimentPolicy.pairStepMode(
            enabled: false, selected: .missionControlTwice, hadGestureFallback: false),
                       .missionControl)
        XCTAssertEqual(GlobalInstantExperimentPolicy.pairStepMode(
            enabled: false, selected: .missionControlTwice, hadGestureFallback: true),
                       .missionControl)
    }
}
