import Foundation
import XCTest
@testable import ONIWACore

final class SpaceLabelsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "com.hiro259.oniwa.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        suite = nil
        super.tearDown()
    }

    private func space(_ display: String = "builtin", _ id: UInt64 = 1,
                       _ uuid: String? = "AABB-1234") -> SpaceIdentity {
        SpaceIdentity(displayID: display, managedID: id, uuid: uuid)
    }

    func testRenamingDoesNotDependOnMissionControlPositionOrRuntimeID() {
        let store = SpaceLabelStore(defaults: defaults)
        let first = space("builtin", 1, "UUID-123")
        store.reconcile([first])
        store.update(first, name: " 趣味 ", aliases: " shumi chrome ")

        let sameSpaceAfterReorder = space("builtin", 9, "uuid-123")
        XCTAssertEqual(store.label(for: sameSpaceAfterReorder),
                       SpaceLabel(name: "趣味", aliases: "shumi chrome"))
        XCTAssertNotEqual(first.runtimeKey, sameSpaceAfterReorder.runtimeKey)
    }

    func testNameAndAliasesPersistAfterAppRelaunch() {
        let identity = space()
        let store = SpaceLabelStore(defaults: defaults)
        store.update(identity, name: "開発", aliases: "kai code")
        let reopened = SpaceLabelStore(defaults: defaults)
        reopened.reconcile([identity])
        XCTAssertEqual(reopened.label(for: identity)?.name, "開発")
        XCTAssertEqual(reopened.label(for: identity)?.aliases, "kai code")
    }

    func testTwoFullscreenSpacesOfSameAppRemainIndependent() {
        let first = space("builtin", 10, "chrome-fullscreen-1")
        let second = space("builtin", 20, "chrome-fullscreen-2")
        let store = SpaceLabelStore(defaults: defaults)
        store.update(first, name: "仕事", aliases: "work")
        store.update(second, name: "趣味", aliases: "shumi")
        XCTAssertEqual(store.label(for: first)?.name, "仕事")
        XCTAssertEqual(store.label(for: second)?.name, "趣味")
        XCTAssertEqual(SpaceLabelStore(defaults: defaults).label(for: second)?.name, "趣味")
    }

    func testDisplayScopesLabelsEvenWhenSystemReportsSameUUID() {
        let first = space("builtin", 100, "duplicate")
        let other = space("sidecar", 100, "duplicate")
        let store = SpaceLabelStore(defaults: defaults)
        store.update(first, name: "Mac", aliases: "")
        XCTAssertNil(store.label(for: other))
        store.update(other, name: "iPad", aliases: "")
        XCTAssertEqual(store.label(for: first)?.name, "Mac")
        XCTAssertEqual(store.label(for: other)?.name, "iPad")
    }

    func testUUIDMissingMeansSessionOnlyNotPositionBasedPersistence() {
        let first = space("builtin", 90, nil)
        let store = SpaceLabelStore(defaults: defaults)
        store.reconcile([first])
        store.update(first, name: "一時的な名前", aliases: "temp")
        XCTAssertEqual(store.label(for: first)?.name, "一時的な名前")
        XCTAssertNil(first.persistentKey)
        XCTAssertNil(SpaceLabelStore(defaults: defaults).label(for: first))
        XCTAssertNil(store.label(for: space("builtin", 91, nil)))
    }

    func testTransientLabelsArePrunedWhenSpaceDisappears() {
        let transient = space("builtin", 10, "")
        let store = SpaceLabelStore(defaults: defaults)
        store.reconcile([transient])
        store.update(transient, name: "消える名前", aliases: "")
        store.reconcile([space("builtin", 20, nil)])
        XCTAssertNil(store.label(for: transient))
    }

    func testDeletingNameAndAliasesRemovesPersistentLabel() {
        let identity = space()
        let store = SpaceLabelStore(defaults: defaults)
        store.update(identity, name: "ホームページ", aliases: "hp")
        store.update(identity, name: "", aliases: "   ")
        XCTAssertNil(store.label(for: identity))
        XCTAssertNil(SpaceLabelStore(defaults: defaults).label(for: identity))
    }

    func testBlankNameCanKeepSearchAliases() {
        let identity = space()
        let store = SpaceLabelStore(defaults: defaults)
        store.update(identity, name: "  ", aliases: " shumi ")
        XCTAssertEqual(store.label(for: identity), SpaceLabel(name: "", aliases: "shumi"))
    }

    func testLegacyUUIDMigratesButLegacyPositionDoesNot() throws {
        let previous: [String: SpaceLabel] = [
            "uuid:abc": SpaceLabel(name: "旧名", aliases: "alias"),
            "position:builtin:1": SpaceLabel(name: "危険な名前", aliases: "wrong")
        ]
        defaults.set(try JSONEncoder().encode(previous), forKey: "oniwa.customLabels.v1")
        let store = SpaceLabelStore(defaults: defaults)
        let stable = space("builtin", 40, "abc")
        let withoutUUID = space("builtin", 50, nil)
        store.reconcile([stable, withoutUUID])
        XCTAssertEqual(store.label(for: stable)?.name, "旧名")
        XCTAssertNil(store.label(for: withoutUUID))
        XCTAssertEqual(SpaceLabelStore(defaults: defaults).label(for: stable)?.name, "旧名")
    }

    func testDeletedMigratedNameDoesNotResurrect() throws {
        defaults.set(try JSONEncoder().encode([
            "uuid:abc": SpaceLabel(name: "旧名", aliases: "old")
        ]), forKey: "oniwa.customLabels.v1")
        let identity = space("builtin", 1, "abc")
        let store = SpaceLabelStore(defaults: defaults)
        store.reconcile([identity])
        XCTAssertEqual(store.label(for: identity)?.name, "旧名")
        store.update(identity, name: "", aliases: "")
        store.reconcile([identity])
        XCTAssertNil(store.label(for: identity))
        let relaunched = SpaceLabelStore(defaults: defaults)
        relaunched.reconcile([identity])
        XCTAssertNil(relaunched.label(for: identity))
    }

    func testManualRenameCannotReimportOldLegacyName() throws {
        defaults.set(try JSONEncoder().encode([
            "uuid:abc": SpaceLabel(name: "旧名", aliases: "")
        ]), forKey: "oniwa.customLabels.v1")
        let identity = space("builtin", 7, "abc")
        let store = SpaceLabelStore(defaults: defaults)
        store.update(identity, name: "新名", aliases: "")
        store.update(identity, name: "", aliases: "")
        store.reconcile([identity])
        XCTAssertNil(store.label(for: identity))
    }

    func testAmbiguousOldUUIDIsNotMigratedAcrossDisplays() throws {
        defaults.set(try JSONEncoder().encode([
            "uuid:shared": SpaceLabel(name: "誤移行防止", aliases: "")
        ]), forKey: "oniwa.customLabels.v1")
        let first = space("builtin", 1, "shared")
        let second = space("sidecar", 1, "shared")
        let store = SpaceLabelStore(defaults: defaults)
        store.reconcile([first, second])
        XCTAssertNil(store.label(for: first))
        XCTAssertNil(store.label(for: second))
    }

    func testNormalizesEmptyUUIDToNilAndTrimsInput() {
        let identity = space("builtin", 1, "   ")
        XCTAssertNil(identity.persistentKey)
        XCTAssertEqual(SpaceLabel(name: "  趣味 ", aliases: " shumi ").name, "趣味")
        XCTAssertEqual(SpaceLabel(name: "  趣味 ", aliases: " shumi ").aliases, "shumi")
    }
}
