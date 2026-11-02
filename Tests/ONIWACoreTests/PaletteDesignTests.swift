import XCTest
@testable import ONIWACore

final class PaletteDesignTests: XCTestCase {
    func testEightDistinctStablePresets() {
        XCTAssertEqual(PaletteDesign.allCases.count, 8)
        XCTAssertEqual(Set(PaletteDesign.allCases.map(\.rawValue)).count, 8)
        XCTAssertTrue(PaletteDesign.allCases.allSatisfy {
            !$0.title.isEmpty && !$0.detail.isEmpty
        })
        XCTAssertEqual(PaletteDesign.allCases[5], .modernPrecision)
        XCTAssertEqual(PaletteDesign.allCases[6], .pureMonochrome)
        XCTAssertEqual(PaletteDesign.allCases[7], .macOSNative)
    }

    func testUnknownOrMissingValueUsesNativeDefault() {
        let suite = "oniwa.palette.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(PaletteDesign.selected(in: defaults), .macOSNative)
        XCTAssertEqual(PaletteDesign.active(in: defaults), .macOSNative)
        defaults.set("unrecognized-future-preset", forKey: PaletteDesign.settingsKey)
        XCTAssertEqual(PaletteDesign.selected(in: defaults), .macOSNative)
        XCTAssertEqual(PaletteDesign.active(in: defaults), .macOSNative)
    }

    func testOnlyMacOSNativeIsExposedWithoutDeletingTheOtherPresets() {
        XCTAssertEqual(PaletteDesign.visiblePresets, [.macOSNative])
        XCTAssertEqual(PaletteDesign.allCases.count, 8)
        XCTAssertEqual(PaletteDesign.active(rawValue: nil), .macOSNative)
        XCTAssertEqual(PaletteDesign.active(rawValue: PaletteDesign.macOSNative.rawValue),
                       .macOSNative)
        XCTAssertEqual(PaletteDesign.active(rawValue: "invalid"), .macOSNative)
    }

    func testPreviouslySavedHiddenPresetsShowNativeWithoutErasingPreference() {
        let suite = "oniwa.palette.hidden.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        for design in PaletteDesign.allCases where design != .macOSNative {
            design.persist(in: defaults)
            XCTAssertEqual(PaletteDesign.selected(in: defaults), design)
            XCTAssertEqual(PaletteDesign.active(in: defaults), .macOSNative)
            XCTAssertEqual(defaults.string(forKey: PaletteDesign.settingsKey),
                           design.rawValue)
        }
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
