import XCTest
@testable import ONIWACore

final class AppLanguageTests: XCTestCase {
    func testDefaultAndUnknownLanguageAreJapanese() {
        let suite = "oniwa.language.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AppLanguage.selected(in: defaults), .japanese)
        defaults.set("unknown", forKey: AppLanguage.settingsKey)
        XCTAssertEqual(AppLanguage.selected(in: defaults), .japanese)
    }

    func testBothLanguagesPersistAndTranslate() {
        let suite = "oniwa.language.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(AppLanguage.allCases.count, 2)
        for language in AppLanguage.allCases {
            language.persist(in: defaults)
            XCTAssertEqual(AppLanguage.selected(in: defaults), language)
        }
        XCTAssertEqual(AppLanguage.japanese.text("保存", "Save"), "保存")
        XCTAssertEqual(AppLanguage.english.text("保存", "Save"), "Save")
    }
}
