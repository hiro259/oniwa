import XCTest
@testable import ONIWACore

final class DesktopNumberShortcutPolicyTests: XCTestCase {
    func testDesktopOrdinalsSkipFullscreenSpaceEntries() {
        XCTAssertEqual(DesktopNumberShortcutPolicy.plan(
            kinds: [0, 4, 4, 0, 4, 0], targetIndex: 3),
            .direct(number: 2, keyCode: 19))
        XCTAssertEqual(DesktopNumberShortcutPolicy.plan(
            kinds: [0, 4, 4, 0, 4, 0], targetIndex: 5),
            .direct(number: 3, keyCode: 20))
    }

    func testAllNineNumberKeyCodes() {
        let codes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        for (index, code) in codes.enumerated() {
            XCTAssertEqual(DesktopNumberShortcutPolicy.plan(
                kinds: Array(repeating: 0, count: 9), targetIndex: index),
                .direct(number: index + 1, keyCode: code))
        }
    }

    func testUnsupportedKindsAndNumbersNeverEmitShortcuts() {
        XCTAssertEqual(DesktopNumberShortcutPolicy.plan(
            kinds: [0, 4], targetIndex: 1),
            .fallback(reason: "not-a-desktop"))
        XCTAssertEqual(DesktopNumberShortcutPolicy.plan(
            kinds: Array(repeating: 0, count: 10), targetIndex: 9),
            .fallback(reason: "desktop-number-outside-1-9"))
        XCTAssertEqual(DesktopNumberShortcutPolicy.plan(
            kinds: [0], targetIndex: 9),
            .fallback(reason: "target-index-out-of-range"))
    }
}
