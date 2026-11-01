import XCTest
@testable import ONIWACore

final class SpacePairsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "com.hiro259.oniwa.pairs.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        suite = nil
        super.tearDown()
    }

    private func identity(_ display: String, _ id: UInt64, _ uuid: String?) -> SpaceIdentity {
        SpaceIdentity(displayID: display, managedID: id, uuid: uuid)
    }

    private func pair(_ first: SpaceIdentity, _ second: SpaceIdentity,
                      name: String = "ONIWA開発") -> SpacePair {
        SpacePair(name: name,
                  first: SpacePairTarget(identity: first)!,
                  second: SpacePairTarget(identity: second)!)
    }

    func testPersistsTwoDisplayPairAndReloads() {
        let a = identity("monitor1", 101, "A-UUID")
        let b = identity("monitor2", 201, "B-UUID")
        let entry = pair(a, b, name: "  ONIWA開発  ")
        let store = SpacePairStore(defaults: defaults)
        XCTAssertTrue(store.save(entry))
        let reopened = SpacePairStore(defaults: defaults)
        XCTAssertEqual(reopened.pairs, [SpacePair(id: entry.id, name: "ONIWA開発",
                                                first: entry.first, second: entry.second)])
    }

    func testReorderAndNumericSpaceIDChangesDoNotChangePair() {
        let a = identity("monitor1", 101, "A")
        let b = identity("monitor2", 201, "B")
        let saved = pair(a, b)
        let live = [
            identity("monitor2", 999, "B"),
            identity("monitor1", 888, "A")
        ]
        let resolved = SpacePairResolver.resolve(saved, in: live)
        XCTAssertEqual(resolved?.0.managedID, 888)
        XCTAssertEqual(resolved?.1.managedID, 999)
    }

    func testSpaceDisappearsOrIsRecreatedWithAnotherUUID() {
        let saved = pair(identity("monitor1", 101, "A"),
                         identity("monitor2", 201, "B"))
        XCTAssertNil(SpacePairResolver.resolve(saved, in: [
            identity("monitor1", 102, "C"),
            identity("monitor2", 201, "B")
        ]))
        XCTAssertNil(SpacePairResolver.resolve(saved, in: [
            identity("monitor1", 101, "A")
        ]))
    }

    func testDisplayDisconnectOrMoveDoesNotReassignSpace() {
        let saved = pair(identity("monitor1", 101, "A"),
                         identity("monitor2", 201, "B"))
        XCTAssertNil(SpacePairResolver.resolve(saved, in: [
            identity("monitor2", 101, "A"),
            identity("monitor1", 201, "B")
        ]))
        XCTAssertNil(SpacePairResolver.resolve(saved, in: [
            identity("monitor1", 101, "A"),
            identity("sidecar", 201, "B")
        ]))
    }

    func testDuplicateUUIDsFailClosed() {
        let saved = pair(identity("monitor1", 101, "A"),
                         identity("monitor2", 201, "B"))
        XCTAssertNil(SpacePairResolver.resolve(saved, in: [
            identity("monitor1", 101, "A"),
            identity("monitor1", 102, "A"),
            identity("monitor2", 201, "B")
        ]))
    }

    func testNoUUIDAndSameDisplayCannotBeSavedAsPair() {
        XCTAssertNil(SpacePairTarget(identity: identity("monitor1", 10, nil)))
        let a = identity("monitor1", 10, "A")
        let b = identity("monitor1", 11, "B")
        let saved = pair(a, b)
        XCTAssertFalse(SpacePairResolver.valid(saved))
        let store = SpacePairStore(defaults: defaults)
        XCTAssertFalse(store.save(saved))
        XCTAssertTrue(store.pairs.isEmpty)
    }

    func testEditAndDeletePairDoesNotChangeOtherPairs() {
        let a = identity("monitor1", 101, "A")
        let b = identity("monitor2", 201, "B")
        let other = pair(identity("monitor1", 102, "C"),
                         identity("monitor2", 202, "D"), name: "趣味")
        let first = pair(a, b)
        let store = SpacePairStore(defaults: defaults)
        XCTAssertTrue(store.save(first))
        XCTAssertTrue(store.save(other))
        XCTAssertTrue(store.save(SpacePair(id: first.id, name: "新ONIWA",
                                          first: first.first, second: first.second)))
        XCTAssertEqual(store.pairs.count, 2)
        XCTAssertEqual(store.pairs[0].name, "新ONIWA")
        store.delete(id: first.id)
        XCTAssertEqual(SpacePairStore(defaults: defaults).pairs, [other])
    }

    func testInvalidOrBlankPairNameRejected() {
        let saved = pair(identity("monitor1", 101, "A"),
                         identity("monitor2", 201, "B"), name: "   ")
        XCTAssertFalse(SpacePairResolver.valid(saved))
        XCTAssertFalse(SpacePairStore(defaults: defaults).save(saved))
    }

    func testAlreadyVisibleTargetsResolveWithoutAdditionalActions() {
        let a = identity("monitor1", 101, "A")
        let b = identity("monitor2", 201, "B")
        let resolved = SpacePairResolver.resolve(pair(a, b), in: [a, b])
        XCTAssertEqual(resolved?.0.runtimeKey, a.runtimeKey)
        XCTAssertEqual(resolved?.1.runtimeKey, b.runtimeKey)
        // SpaceSwitcher.performSwitch checks currentID before generating events.
    }
}
