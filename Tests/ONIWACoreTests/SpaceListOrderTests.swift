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
}
