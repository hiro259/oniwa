import Foundation
import XCTest
@testable import ONIWACore

final class DetectedAppTagTests: XCTestCase {
    func testClickAddsMultiWordAppNameWithoutSplittingIt() {
        XCTAssertEqual(DetectedAppTag.adding("Google Chrome", to: ["dev"]),
                       ["dev", "Google Chrome"])
        XCTAssertEqual(DetectedAppTag.adding("システム設定", to: []), ["システム設定"])
    }

    func testRepeatedClicksAndCaseWidthVariationsAreIdempotent() {
        let existing = ["Finder", "Google Chrome"]
        XCTAssertEqual(DetectedAppTag.adding("finder", to: existing), existing)
        XCTAssertEqual(DetectedAppTag.adding("Ｇｏｏｇｌｅ Ｃｈｒｏｍｅ", to: existing), existing)
        XCTAssertTrue(DetectedAppTag.isAdded("GOOGLE CHROME", to: existing))
        XCTAssertTrue(DetectedAppTag.isAdded("Ｆｉｎｄｅｒ", to: existing))
        XCTAssertFalse(DetectedAppTag.isAdded("Terminal", to: existing))
    }

    func testInvalidAndBlankAppNamesDoNotBecomeTags() {
        let tags = ["existing"]
        for name in ["", "   ", "  \n ", "Terminal\nInjected", "\u{0000}Finder"] {
            XCTAssertEqual(DetectedAppTag.adding(name, to: tags), tags)
            XCTAssertNil(DetectedAppTag.tagName(from: name))
        }
    }

    func testTagCleaningMatchesManualEntryRules() {
        XCTAssertEqual(DetectedAppTag.adding("  # Finder  ", to: []), ["Finder"])
        XCTAssertEqual(DetectedAppTag.adding("  Finder  ", to: ["finder"]), ["finder"])
        XCTAssertEqual(DetectedAppTag.adding("Safari", to: ["dev", "finder"]),
                       ["dev", "finder", "Safari"])
    }

    func testDetectedAppClickIsOnlyDraftUntilExplicitSave() {
        let suite = "oniwa.detected-app-tag.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let identity = SpaceIdentity(displayID: "built-in", managedID: 2, uuid: "UUID-A")
        let store = SpaceLabelStore(defaults: defaults)
        store.update(identity, name: "work", tags: ["existing"])

        let draft = DetectedAppTag.adding("Google Chrome",
                                         to: store.label(for: identity)!.searchTags)
        XCTAssertEqual(draft, ["existing", "Google Chrome"])
        // Simulate the editor's Cancel action: no store mutation is performed.
        XCTAssertEqual(SpaceLabelStore(defaults: defaults)
            .label(for: identity)?.searchTags, ["existing"])

        store.update(identity, name: "work", tags: draft)
        XCTAssertEqual(SpaceLabelStore(defaults: defaults)
            .label(for: identity)?.searchTags, ["existing", "Google Chrome"])
    }

    func testNoChangeToOtherSpaceTags() {
        let suite = "oniwa.detected-app-tag.other.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = SpaceIdentity(displayID: "built-in", managedID: 3, uuid: "UUID-A")
        let second = SpaceIdentity(displayID: "sidecar", managedID: 4, uuid: "UUID-B")
        let store = SpaceLabelStore(defaults: defaults)
        store.update(first, name: "first", tags: ["old"])
        store.update(second, name: "second", tags: ["unchanged"])
        store.update(first, name: "first",
                     tags: DetectedAppTag.adding("Finder", to: ["old"]))
        let reopened = SpaceLabelStore(defaults: defaults)
        XCTAssertEqual(reopened.label(for: second)?.searchTags, ["unchanged"])
        XCTAssertEqual(reopened.label(for: first)?.searchTags, ["old", "Finder"])
    }
}
