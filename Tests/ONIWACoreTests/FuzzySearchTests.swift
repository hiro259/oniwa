import XCTest
@testable import ONIWACore

final class FuzzySearchTests: XCTestCase {
    func testExactBeatsPrefix() {
        let items = ["homework", "home", "homepage"]
        let result = FuzzySearch.sorted(items, query: "home") { [$0] }
        XCTAssertEqual(result.first, "home")
    }

    func testMultipleTokensAcrossFields() {
        XCTAssertNotNil(FuzzySearch.score(query: "shumi chrom",
                    fields: ["趣味", "shumi", "Google Chrome"]))
        XCTAssertNil(FuzzySearch.score(query: "shumi slack",
                    fields: ["趣味", "shumi", "Google Chrome"]))
    }

    func testCaseAndWidth() {
        XCTAssertNotNil(FuzzySearch.score(query: "CHROME", fields: ["chrome"]))
        XCTAssertNotNil(FuzzySearch.score(query: "ＡＢＣ", fields: ["abc"]))
    }

    func testSubsequenceAndMissingMatch() {
        XCTAssertNotNil(FuzzySearch.score(query: "hmpe", fields: ["homepage"]))
        XCTAssertNil(FuzzySearch.score(query: "zzz", fields: ["homepage"]))
    }
}
