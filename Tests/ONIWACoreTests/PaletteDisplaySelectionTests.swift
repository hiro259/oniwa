import XCTest
@testable import ONIWACore

final class PaletteDisplaySelectionTests: XCTestCase {
    private let builtIn = "C55E81DB-9EDA-4F22-81CE-5E63E78751AB"
    private let iPad = "F8CA2CE5-297F-40DE-9B31-A6070CC3813D"
    private let external = "BD9C8189-FBD7-4146-B85A-F947FE1F2F37"

    func testDefaultAndMalformedSelectionsUseBuiltIn() {
        for stored in [nil, "", "built-in", "display:", "display:invalid", "display:42"] {
            let selection = PaletteDisplaySelection(storedValue: stored)
            XCTAssertNil(selection.preferredDisplayUUID)
            XCTAssertEqual(selection.storedValue, PaletteDisplaySelection.builtInValue)
            XCTAssertEqual(
                selection.resolvedDisplayUUID(
                    availableUUIDs: [external, builtIn], builtInUUID: builtIn, primaryUUID: external
                ),
                builtIn
            )
        }
    }

    func testConnectedSelectedDisplayWinsOverPrimaryAndBuiltIn() {
        let selection = PaletteDisplaySelection(displayUUID: iPad.lowercased())
        XCTAssertEqual(selection.preferredDisplayUUID, iPad)
        XCTAssertEqual(selection.storedValue, "display:\(iPad)")
        XCTAssertEqual(
            selection.resolvedDisplayUUID(
                availableUUIDs: [external, iPad, builtIn], builtInUUID: builtIn, primaryUUID: external
            ),
            iPad
        )
        XCTAssertEqual(PaletteDisplaySelection(storedValue: selection.storedValue), selection)
    }

    func testDisconnectFallsBackWithoutForgettingPreference() {
        let selection = PaletteDisplaySelection(displayUUID: iPad)
        XCTAssertEqual(
            selection.resolvedDisplayUUID(
                availableUUIDs: [external, builtIn], builtInUUID: builtIn, primaryUUID: external
            ),
            builtIn
        )
        XCTAssertEqual(selection.preferredDisplayUUID, iPad)
        XCTAssertEqual(
            selection.resolvedDisplayUUID(
                availableUUIDs: [iPad, builtIn], builtInUUID: builtIn, primaryUUID: iPad
            ),
            iPad
        )
    }

    func testDesktopMacWithoutBuiltInUsesCurrentPrimary() {
        let selection = PaletteDisplaySelection(displayUUID: iPad)
        XCTAssertEqual(
            selection.resolvedDisplayUUID(
                availableUUIDs: [external], builtInUUID: nil, primaryUUID: external
            ),
            external
        )
    }

    func testNoScreensReturnsNil() {
        let selection = PaletteDisplaySelection(displayUUID: iPad)
        XCTAssertNil(selection.resolvedDisplayUUID(
            availableUUIDs: [], builtInUUID: nil, primaryUUID: nil
        ))
    }
}
