import XCTest
@testable import ONIWACore

final class FuzzySearchTests: XCTestCase {
    private struct Candidate {
        let id: String
        let fields: [SearchField]
    }

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

    func testAliasesBehaveAsKeywordsWithTagsAndSeparators() {
        XCTAssertEqual(FuzzySearch.keywords(in: " #shumi, #Chrome　ONIWA;work、shumi"),
                       ["shumi", "chrome", "oniwa", "work"])
    }

    func testUserNameOutranksSameAppName() {
        let items = [
            Candidate(id: "app", fields: [.init(text: "Chrome", kind: .app)]),
            Candidate(id: "named", fields: [.init(text: "Chrome", kind: .name)]),
            Candidate(id: "keyword", fields: [.init(text: "Chrome", kind: .keyword)])
        ]
        let result = FuzzySearch.ranked(items, query: "chrome") { $0.fields }
        XCTAssertEqual(result.map(\.id), ["named", "keyword", "app"])
    }

    func testExplicitShortKeywordBeatsMatchingAppPrefix() {
        let items = [
            Candidate(id: "app", fields: [.init(text: "homepage", kind: .app)]),
            Candidate(id: "hp", fields: [
                .init(text: "ホームページ制作", kind: .name),
                .init(text: "hp", kind: .keyword)
            ])
        ]
        XCTAssertEqual(FuzzySearch.ranked(items, query: "hp") { $0.fields }.first?.id,
                       "hp")
    }

    func testUserSuppliedRomajiKeywordsWithTwoSearchTerms() {
        let items = [
            Candidate(id: "hobby", fields: [
                .init(text: "趣味", kind: .name),
                .init(text: "shumi", kind: .keyword),
                .init(text: "Google Chrome", kind: .app)
            ]),
            Candidate(id: "work", fields: [
                .init(text: "仕事", kind: .name),
                .init(text: "shigoto", kind: .keyword),
                .init(text: "Google Chrome", kind: .app)
            ])
        ]
        let ids = FuzzySearch.ranked(items, query: "#shumi chrome") { $0.fields }.map(\.id)
        XCTAssertEqual(ids, ["hobby"])
        // Kanji-to-romaji is not automatic: the user must register "shumi".
        XCTAssertNil(FuzzySearch.score(query: "shumi", fields: ["趣味"]))
    }

    func testMultipleKeywordsCanMatchDifferentFields() {
        let items = [
            Candidate(id: "dev", fields: [
                .init(text: "開発", kind: .name),
                .init(text: "kai", kind: .keyword),
                .init(text: "Terminal", kind: .app)
            ])
        ]
        XCTAssertEqual(FuzzySearch.ranked(items, query: "kai terminal") { $0.fields }.count, 1)
        XCTAssertTrue(FuzzySearch.ranked(items, query: "kai slack") { $0.fields }.isEmpty)
    }

    func testEmptyQueryKeepsOriginalOrderAndOnlyTagMarkerMatchesNothing() {
        let items = [
            Candidate(id: "first", fields: [.init(text: "Alpha", kind: .name)]),
            Candidate(id: "second", fields: [.init(text: "Beta", kind: .name)])
        ]
        XCTAssertEqual(FuzzySearch.ranked(items, query: "") { $0.fields }.map(\.id),
                       ["first", "second"])
        XCTAssertTrue(FuzzySearch.ranked(items, query: "#") { $0.fields }.isEmpty)
    }

    func testWordPrefixMatchesAppNameAndOutranksSubsequence() {
        let items = [
            Candidate(id: "fuzzy", fields: [.init(text: "C-h-r-o-m-e", kind: .app)]),
            Candidate(id: "word", fields: [.init(text: "Google Chrome", kind: .app)])
        ]
        XCTAssertEqual(FuzzySearch.ranked(items, query: "chrome") { $0.fields }.first?.id,
                       "word")
    }
}
