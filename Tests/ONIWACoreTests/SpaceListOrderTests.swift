import XCTest
@testable import ONIWACore

final class SpaceListOrderTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "oniwa.order.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testUnseenItemsKeepSourceOrder() {
        let order = SpaceListOrderStore(defaults: defaults())
        XCTAssertEqual(order.orderedKeys(["a", "b", "c"]), ["a", "b", "c"])
    }

    func testPinsComeFirstInStablePinOrderRegardlessOfRecentUse() {
        let order = SpaceListOrderStore(defaults: defaults())
        order.togglePin("space-a")
        order.togglePin("pair-b")
        order.markUsed("space-c")
        order.markUsed("pair-b")
        order.markUsed("space-a")
        XCTAssertEqual(order.orderedKeys(["space-c", "pair-b", "space-a"]),
                       ["space-a", "pair-b", "space-c"])
        order.togglePin("space-a")
        order.togglePin("space-a")
        XCTAssertEqual(order.orderedKeys(["space-c", "pair-b", "space-a"]),
                       ["pair-b", "space-a", "space-c"])
    }

    func testRecentSuccessOrderSurvivesRestart() {
        let defaults = defaults()
        let order = SpaceListOrderStore(defaults: defaults)
        order.markUsed("space-a")
        order.markUsed("space-b")
        order.markUsed("space-a")
        order.togglePin("pair-c")
        let restarted = SpaceListOrderStore(defaults: defaults)
        XCTAssertTrue(restarted.isPinned("pair-c"))
        XCTAssertEqual(restarted.orderedKeys(["space-b", "pair-c", "space-a", "new"]),
                       ["pair-c", "space-a", "space-b", "new"])
    }

    func testSearchKeepsFuzzyRankingExceptMatchingPins() {
        let order = SpaceListOrderStore(defaults: defaults())
        order.markUsed("low-ranked")
        order.togglePin("pinned")
        XCTAssertEqual(order.orderedKeys(["high-ranked", "low-ranked", "pinned"],
                                         useRecency: false),
                       ["pinned", "high-ranked", "low-ranked"])
    }

    func testDeletingPairRemovesPinnedAndRecencyState() {
        let order = SpaceListOrderStore(defaults: defaults())
        order.togglePin("pair:old")
        order.markUsed("pair:old")
        order.remove("pair:old")
        XCTAssertFalse(order.isPinned("pair:old"))
        XCTAssertEqual(order.orderedKeys(["space", "pair:old"]), ["space", "pair:old"])
    }

    func testSpaceKeyIsMonitorScopedAndIndependentOfRuntimeManagedID() {
        let a = SpaceIdentity(displayID: "display-one", managedID: 40, uuid: "AAA")
        let b = SpaceIdentity(displayID: "display-one", managedID: 77, uuid: "aaa")
        let other = SpaceIdentity(displayID: "display-two", managedID: 40, uuid: "AAA")
        XCTAssertEqual(a.persistentKey, b.persistentKey)
        XCTAssertNotEqual(a.persistentKey, other.persistentKey)
    }
    func testOriginalAndNameModesWithPinnedPriority() {
        let order = SpaceListOrderStore(defaults: defaults())
        let keys = ["b", "c", "a"]
        order.markUsed("c")
        order.setSortMode(.original, visibleKeys: keys)
        XCTAssertEqual(order.orderedKeys(keys), ["b", "c", "a"])
        order.setSortMode(.name, visibleKeys: keys)
        XCTAssertEqual(order.orderedKeys(keys, names: [
            "a": "Alps", "b": "Zebra", "c": "cafe"
        ]), ["a", "c", "b"])
        order.togglePin("b")
        XCTAssertEqual(order.orderedKeys(keys, names: [
            "a": "Alps", "b": "Zebra", "c": "cafe"
        ]), ["b", "a", "c"])
    }

    func testManualDragPersistenceAndPinBoundaries() {
        let defaults = defaults()
        let order = SpaceListOrderStore(defaults: defaults)
        let keys = ["pair", "a", "b", "c"]
        order.togglePin("pair")
        order.setSortMode(.custom, visibleKeys: keys)
        XCTAssertEqual(order.orderedKeys(keys), keys)
        XCTAssertTrue(order.moveCustom("a", to: "c", visibleKeys: keys))
        XCTAssertEqual(order.orderedKeys(keys), ["pair", "b", "c", "a"])
        XCTAssertFalse(order.moveCustom("a", to: "pair", visibleKeys: keys))
        XCTAssertEqual(order.orderedKeys(keys), ["pair", "b", "c", "a"])
        let restarted = SpaceListOrderStore(defaults: defaults)
        XCTAssertEqual(restarted.sortMode, .custom)
        XCTAssertEqual(restarted.orderedKeys(keys), ["pair", "b", "c", "a"])
        XCTAssertEqual(restarted.orderedKeys(["a", "c"], useRecency: false),
                       ["a", "c"])
    }

    func testCustomModePreservesManualOrderAcrossOtherModesAndNewItems() {
        let order = SpaceListOrderStore(defaults: defaults())
        order.setSortMode(.custom, visibleKeys: ["a", "b"])
        XCTAssertTrue(order.moveCustom("b", to: "a", visibleKeys: ["a", "b"]))
        order.setSortMode(.recent, visibleKeys: ["a", "b"])
        order.markUsed("a")
        order.setSortMode(.custom, visibleKeys: ["a", "b", "c"])
        XCTAssertEqual(order.orderedKeys(["a", "b", "c"]), ["b", "a", "c"])
    }

    func testLegacySnapshotDecodesWithoutLosingPins() throws {
        let defaults = defaults()
        let data = Data(#"{"pinned":["a"],"recent":["b"]}"#.utf8)
        defaults.set(data, forKey: "oniwa.spaceListOrder.v1")
        let order = SpaceListOrderStore(defaults: defaults)
        XCTAssertEqual(order.sortMode, .recent)
        XCTAssertTrue(order.isPinned("a"))
        XCTAssertEqual(order.orderedKeys(["b", "a"]), ["a", "b"])
    }

    func testTransientSpaceKeysDoNotEnterPersistedCustomOrder() {
        let defaults = defaults()
        let runtime = "transient:runtime:display:123"
        let order = SpaceListOrderStore(defaults: defaults)
        order.setSortMode(.custom, visibleKeys: ["stable-a", runtime, "stable-b"])
        XCTAssertFalse(order.moveCustom(runtime, to: "stable-a",
                                        visibleKeys: ["stable-a", runtime, "stable-b"]))
        XCTAssertTrue(order.moveCustom("stable-b", to: "stable-a",
                                       visibleKeys: ["stable-a", runtime, "stable-b"]))
        let restarted = SpaceListOrderStore(defaults: defaults)
        XCTAssertEqual(restarted.orderedKeys(["stable-a", "stable-b", runtime]),
                       ["stable-b", "stable-a", runtime])
    }

}
