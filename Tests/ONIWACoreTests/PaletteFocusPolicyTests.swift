import XCTest
@testable import ONIWACore

final class PaletteFocusPolicyTests: XCTestCase {
    func testVisibleKeyPaletteCanRestoreSearchFocus() {
        XCTAssertTrue(PaletteFocusPolicy.shouldRestoreSearchFocus(
            isVisible: true, isKeyWindow: true,
            isEditingSpace: false, isEditingPair: false))
    }

    func testHiddenPaletteNeverRestoresSearchFocus() {
        XCTAssertFalse(PaletteFocusPolicy.shouldRestoreSearchFocus(
            isVisible: false, isKeyWindow: true,
            isEditingSpace: false, isEditingPair: false))
    }

    func testNonKeyPaletteNeverStealsFocusFromAnotherWindow() {
        XCTAssertFalse(PaletteFocusPolicy.shouldRestoreSearchFocus(
            isVisible: true, isKeyWindow: false,
            isEditingSpace: false, isEditingPair: false))
    }

    func testEditingSpaceDoesNotLoseKeyboardFocus() {
        XCTAssertFalse(PaletteFocusPolicy.shouldRestoreSearchFocus(
            isVisible: true, isKeyWindow: true,
            isEditingSpace: true, isEditingPair: false))
    }

    func testEditingPairDoesNotLoseKeyboardFocus() {
        XCTAssertFalse(PaletteFocusPolicy.shouldRestoreSearchFocus(
            isVisible: true, isKeyWindow: true,
            isEditingSpace: false, isEditingPair: true))
    }
}
