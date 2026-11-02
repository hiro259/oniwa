import XCTest
@testable import ONIWACore

final class GlassTransparencySettingsTests: XCTestCase {
    func testDefaultAndStoredValues() {
        let suite = "oniwa.glass.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Couldn't create an isolated defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(GlassTransparencySettings.selected(in: defaults), 20)
        GlassTransparencySettings.persist(65, in: defaults)
        XCTAssertEqual(GlassTransparencySettings.selected(in: defaults), 65)
    }

    func testValuesAreClamped() {
        let suite = "oniwa.glass.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Couldn't create an isolated defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        GlassTransparencySettings.persist(-40, in: defaults)
        XCTAssertEqual(GlassTransparencySettings.selected(in: defaults), 0)
        GlassTransparencySettings.persist(1000, in: defaults)
        XCTAssertEqual(GlassTransparencySettings.selected(in: defaults), 100)
        defaults.set(-10, forKey: GlassTransparencySettings.settingsKey)
        XCTAssertEqual(GlassTransparencySettings.selected(in: defaults), 0)
    }

    func testOpacityHonorsAccessibilityContrast() {
        XCTAssertEqual(GlassTransparencySettings.backgroundOpacity(percent: 0, increasedContrast: false), 1.0)
        XCTAssertEqual(GlassTransparencySettings.backgroundOpacity(percent: 20, increasedContrast: false), 0.8)
        XCTAssertEqual(GlassTransparencySettings.backgroundOpacity(percent: 100, increasedContrast: false), 0.0)
        XCTAssertEqual(GlassTransparencySettings.backgroundOpacity(percent: 100, increasedContrast: true), 0.94)
        XCTAssertEqual(GlassTransparencySettings.backgroundOpacity(percent: 0, increasedContrast: true), 1.0)
    }
}
