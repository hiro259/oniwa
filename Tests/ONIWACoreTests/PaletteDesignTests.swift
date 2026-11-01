import XCTest
@testable import ONIWACore

final class PaletteDesignTests: XCTestCase {
    func testSevenDistinctStablePresets() {
        XCTAssertEqual(PaletteDesign.allCases.count, 7)
        XCTAssertEqual(Set(PaletteDesign.allCases.map(\.rawValue)).count, 5)
        XCTAssertTrue(PaletteDesign.allCases.allSatisfy {
            !$0.title.isEmpty && !$0.detail.isEmpty
        })
        XCTAssertEqual(PaletteDesign.allCases[5], .modernPrecision)
        XCTAssertEqual(PaletteDesign.allCases[6], .pureMonochrome)
    }

    func testUnknownOrMissingValueUsesNativeDefault() {
        let suite = "oniwa.palette.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(PaletteDesign.selected(in: defaults), .nativeCalm)
        defaults.set("unrecognized-future-preset", forKey: PaletteDesign.settingsKey)
        XCTAssertEqual(PaletteDesign.selected(in: defaults), .nativeCalm)
    }

    func testEveryPresetSurvivesPersistenceRoundtrip() {
        let suite = "oniwa.palette.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        for design in PaletteDesign.allCases {
            design.persist(in: defaults)
            XCTAssertEqual(PaletteDesign.selected(in: defaults), design)
        }
    }
}
