import XCTest
@testable import ONIWACore

final class AppLanguageTests: XCTestCase {
    func testPrimaryMacOSLanguageDeterminesAutomaticUI() {
        XCTAssertEqual(AppLanguage.systemPreferred(preferredLanguages: ["ja"]), .japanese)
        XCTAssertEqual(AppLanguage.systemPreferred(preferredLanguages: ["ja-JP", "en-US"]), .japanese)
        XCTAssertEqual(AppLanguage.systemPreferred(preferredLanguages: ["ja_JP"]), .japanese)
        XCTAssertEqual(AppLanguage.systemPreferred(preferredLanguages: ["en-US", "ja-JP"]), .english)
        XCTAssertEqual(AppLanguage.systemPreferred(preferredLanguages: ["fr-FR", "ja-JP"]), .english)
        XCTAssertEqual(AppLanguage.systemPreferred(preferredLanguages: ["zh-Hans-CN"]), .english)
        XCTAssertEqual(AppLanguage.systemPreferred(preferredLanguages: []), .english)
    }

    func testMissingAutomaticAndUnknownValuesFollowSystem() {
        let suite = "oniwa.language.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("Could not create isolated UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(AppLanguage.isFollowingSystem(in: defaults))
        XCTAssertEqual(AppLanguage.selected(in: defaults, preferredLanguages: ["ja-JP"]), .japanese)
        XCTAssertEqual(AppLanguage.selected(in: defaults, preferredLanguages: ["en-US"]), .english)

        defaults.set(AppLanguage.automaticValue, forKey: AppLanguage.settingsKey)
        XCTAssertTrue(AppLanguage.isFollowingSystem(in: defaults))
        XCTAssertEqual(AppLanguage.selected(in: defaults, preferredLanguages: ["ja-JP"]), .japanese)

        defaults.set("unknown", forKey: AppLanguage.settingsKey)
        XCTAssertTrue(AppLanguage.isFollowingSystem(in: defaults))
        XCTAssertEqual(AppLanguage.selected(in: defaults, preferredLanguages: ["en-US"]), .english)
    }

    func testManualPreferenceSurvivesSystemLanguageChangesAndCanReset() {
        let suite = "oniwa.language.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("Could not create isolated UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(AppLanguage.allCases.count, 2)
        for language in AppLanguage.allCases {
            language.persist(in: defaults)
            XCTAssertFalse(AppLanguage.isFollowingSystem(in: defaults))
            XCTAssertEqual(AppLanguage.selected(in: defaults, preferredLanguages: ["ja-JP"]), language)
            XCTAssertEqual(AppLanguage.selected(in: defaults, preferredLanguages: ["en-US"]), language)
            XCTAssertEqual(defaults.string(forKey: AppLanguage.settingsKey), language.rawValue)
        }

        AppLanguage.followSystem(in: defaults)
        XCTAssertEqual(defaults.string(forKey: AppLanguage.settingsKey), AppLanguage.automaticValue)
        XCTAssertTrue(AppLanguage.isFollowingSystem(in: defaults))
        XCTAssertEqual(AppLanguage.selected(in: defaults, preferredLanguages: ["ja-JP"]), .japanese)
        XCTAssertEqual(AppLanguage.selected(in: defaults, preferredLanguages: ["en-US"]), .english)
        XCTAssertEqual(AppLanguage.japanese.text("保存", "Save"), "保存")
        XCTAssertEqual(AppLanguage.english.text("保存", "Save"), "Save")
    }

    func testSwiftUIRawPreferenceResolution() {
        XCTAssertEqual(AppLanguage.effective(rawValue: nil, preferredLanguages: ["ja-JP"]), .japanese)
        XCTAssertEqual(AppLanguage.effective(rawValue: "system", preferredLanguages: ["en-GB"]), .english)
        XCTAssertEqual(AppLanguage.effective(rawValue: "ja", preferredLanguages: ["en-US"]), .japanese)
        XCTAssertEqual(AppLanguage.effective(rawValue: "en", preferredLanguages: ["ja-JP"]), .english)
    }
}
