import XCTest
@testable import ONIWACore

final class UUIDlessDesktopPolicyTests: XCTestCase {
    private func record(_ kind: Int = 0, _ uuid: String?) -> SpaceUUIDRecord {
        SpaceUUIDRecord(kind: kind, rawUUID: uuid)
    }

    func testUniqueExplicitEmptyUUIDGetsAnchor() {
        let spaces = [record(0, ""), record(0, "normal-uuid"), record(4, "fullscreen-uuid")]
        XCTAssertEqual(UUIDlessDesktopPolicy.anchorIndex(in: spaces), 0)
    }

    func testUniqueEmptyUUIDStaysSameDesktopWhenReordered() {
        let spaces = [record(0, "normal-uuid"), record(4, "fullscreen-uuid"),
                      record(0, "  ")]
        XCTAssertEqual(UUIDlessDesktopPolicy.anchorIndex(in: spaces), 2)
    }

    func testMissingUUIDFieldIsNotTreatedAsKnownEmptyPrimaryDesktop() {
        XCTAssertNil(UUIDlessDesktopPolicy.anchorIndex(in: [
            record(0, nil), record(0, "another")
        ]))
    }

    func testDuplicateOrAmbiguousEmptyUUIDsFailClosed() {
        XCTAssertNil(UUIDlessDesktopPolicy.anchorIndex(in: [
            record(0, ""), record(0, "")
        ]))
        XCTAssertNil(UUIDlessDesktopPolicy.anchorIndex(in: [
            record(0, ""), record(4, nil)
        ]))
    }

    func testFullscreenOrNormalUUIDIsNotAnchored() {
        XCTAssertNil(UUIDlessDesktopPolicy.anchorIndex(in: [
            record(4, ""), record(0, "normal")
        ]))
        XCTAssertNil(UUIDlessDesktopPolicy.anchorIndex(in: [
            record(0, "uuid-a"), record(0, "uuid-b")
        ]))
    }

    func testSpecialIdentityIsDisplayScopedAndIndependentOfNumericID() {
        let original = SpaceIdentity(displayID: "built-in", managedID: 1,
                                     uuid: "", isUUIDlessDesktopAnchor: true)
        let afterRestart = SpaceIdentity(displayID: "built-in", managedID: 800,
                                         uuid: " ", isUUIDlessDesktopAnchor: true)
        let sidecar = SpaceIdentity(displayID: "sidecar", managedID: 1,
                                    uuid: "", isUUIDlessDesktopAnchor: true)
        XCTAssertEqual(original.persistentKey, afterRestart.persistentKey)
        XCTAssertNotEqual(original.runtimeKey, afterRestart.runtimeKey)
        XCTAssertNotEqual(original.persistentKey, sidecar.persistentKey)
        XCTAssertEqual(original.persistentKey, "space.uuidless-primary.v1:built-in")
        XCTAssertNil(original.uuid)
    }

    func testOtherMissingUUIDSpacesStaySessionOnlyAndNormalKeysAreUnchanged() {
        XCTAssertNil(SpaceIdentity(displayID: "built-in", managedID: 1,
                                   uuid: nil).persistentKey)
        XCTAssertNil(SpaceIdentity(displayID: "built-in", managedID: 1,
                                   uuid: "").persistentKey)
        let regular = SpaceIdentity(displayID: "built-in", managedID: 2,
                                    uuid: "REAL-UUID", isUUIDlessDesktopAnchor: true)
        XCTAssertEqual(regular.persistentKey, "space.v2:built-in:real-uuid")
        XCTAssertFalse(regular.isUUIDlessDesktopAnchor)
    }

    func testPinAndLabelPersistAcrossRelaunchForUniqueEmptyUUID() {
        let name = "oniwa.uuidless.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        let original = SpaceIdentity(displayID: "built-in", managedID: 1,
                                     uuid: "", isUUIDlessDesktopAnchor: true)
        let pinStore = SpaceListOrderStore(defaults: defaults)
        let labelStore = SpaceLabelStore(defaults: defaults)
        let key = original.persistentKey!
        XCTAssertTrue(pinStore.togglePin(key))
        labelStore.update(original, name: "作業", tags: ["dev", "home"])

        let reconnected = SpaceIdentity(displayID: "built-in", managedID: 777,
                                        uuid: "", isUUIDlessDesktopAnchor: true)
        XCTAssertTrue(SpaceListOrderStore(defaults: defaults).isPinned(
            reconnected.persistentKey!))
        XCTAssertEqual(SpaceLabelStore(defaults: defaults)
            .label(for: reconnected)?.searchTags, ["dev", "home"])
        XCTAssertEqual(SpaceListOrderStore(defaults: defaults)
            .orderedKeys(["another", reconnected.persistentKey!]),
            [reconnected.persistentKey!, "another"])

        // A replacement with a real UUID is not assigned the old special pin.
        let newDesktop = SpaceIdentity(displayID: "built-in", managedID: 777,
                                       uuid: "new-uuid")
        XCTAssertFalse(SpaceListOrderStore(defaults: defaults).isPinned(
            newDesktop.persistentKey!))
        XCTAssertNil(SpaceLabelStore(defaults: defaults).label(for: newDesktop))
    }

    func testPairTargetStillRejectsPrimaryAnchorWithoutRealUUID() {
        let primary = SpaceIdentity(displayID: "built-in", managedID: 1,
                                    uuid: "", isUUIDlessDesktopAnchor: true)
        XCTAssertNil(SpacePairTarget(identity: primary))
    }
}
