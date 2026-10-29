import XCTest
@testable import ONIWACore

final class InstantSwitchPolicyTests: XCTestCase {
    func testKnownSupportedSystemsOnly() {
        XCTAssertFalse(InstantSwitchPolicy.supportsInstant(major: 15, minor: 9))
        XCTAssertFalse(InstantSwitchPolicy.supportsInstant(major: 26, minor: 0))
        XCTAssertFalse(InstantSwitchPolicy.supportsInstant(major: 26, minor: 5))
        XCTAssertTrue(InstantSwitchPolicy.supportsInstant(major: 26, minor: 6))
        XCTAssertTrue(InstantSwitchPolicy.supportsInstant(major: 26, minor: 7))
        XCTAssertTrue(InstantSwitchPolicy.supportsInstant(major: 27, minor: 0))
        XCTAssertTrue(InstantSwitchPolicy.supportsInstant(major: 27, minor: 3))
        XCTAssertFalse(InstantSwitchPolicy.supportsInstant(major: 28, minor: 0))
    }

    func testFallbackToKeyboardWhenInstantGestureDidNotMove() {
        XCTAssertEqual(InstantSwitchPolicy.fallbackDecision(
            previous: 100, expected: 200, observed: 100, orderUnchanged: true),
            .keyboard)
    }

    func testDoNotIssueAnotherShortcutIfGestureAlreadyArrived() {
        XCTAssertEqual(InstantSwitchPolicy.fallbackDecision(
            previous: 100, expected: 200, observed: 200, orderUnchanged: true),
            .alreadySwitched)
    }

    func testUnexpectedOrUnknownSpaceNeverTriggersFallback() {
        XCTAssertEqual(InstantSwitchPolicy.fallbackDecision(
            previous: 100, expected: 200, observed: 300, orderUnchanged: true),
            .abort)
        XCTAssertEqual(InstantSwitchPolicy.fallbackDecision(
            previous: 100, expected: 200, observed: nil, orderUnchanged: true),
            .abort)
    }

    func testReorderedSpaceNeverTriggersFallback() {
        XCTAssertEqual(InstantSwitchPolicy.fallbackDecision(
            previous: 100, expected: 200, observed: 100, orderUnchanged: false),
            .abort)
    }
}
