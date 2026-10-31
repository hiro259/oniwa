import XCTest
@testable import ONIWACore

final class PairHybridRoutingTests: XCTestCase {
    func testBuiltInFirstGetsMissionControl() {
        let route = PairHybridRouting.resolve(
            firstDisplayID: "INTERNAL", secondDisplayID: "EXTERNAL",
            isBuiltInByDisplayID: ["INTERNAL": true, "EXTERNAL": false])
        XCTAssertEqual(route, PairHybridRoute(
            builtInDisplayID: "INTERNAL", externalDisplayID: "EXTERNAL"))
    }

    func testExternalFirstStillRoutesBuiltInToMissionControl() {
        let route = PairHybridRouting.resolve(
            firstDisplayID: "EXTERNAL", secondDisplayID: "INTERNAL",
            isBuiltInByDisplayID: ["INTERNAL": true, "EXTERNAL": false])
        XCTAssertEqual(route, PairHybridRoute(
            builtInDisplayID: "INTERNAL", externalDisplayID: "EXTERNAL"))
    }

    func testUUIDsAreCaseInsensitive() {
        XCTAssertEqual(PairHybridRouting.resolve(
            firstDisplayID: "abc-DEF", secondDisplayID: "xyz-123",
            isBuiltInByDisplayID: ["ABC-def": true, "XYZ-123": false]),
            PairHybridRoute(builtInDisplayID: "abc-DEF",
                            externalDisplayID: "xyz-123"))
    }

    func testExternalOnlyAndMissingBuiltInRejectWithoutKeypress() {
        XCTAssertNil(PairHybridRouting.resolve(
            firstDisplayID: "ext1", secondDisplayID: "ext2",
            isBuiltInByDisplayID: ["ext1": false, "ext2": false]))
        XCTAssertNil(PairHybridRouting.resolve(
            firstDisplayID: "internal", secondDisplayID: "external",
            isBuiltInByDisplayID: ["external": false]))
    }

    func testTwoBuiltInsAndDuplicateIDsReject() {
        XCTAssertNil(PairHybridRouting.resolve(
            firstDisplayID: "a", secondDisplayID: "b",
            isBuiltInByDisplayID: ["a": true, "b": true]))
        XCTAssertNil(PairHybridRouting.resolve(
            firstDisplayID: "a", secondDisplayID: "A",
            isBuiltInByDisplayID: ["a": true]))
        XCTAssertNil(PairHybridRouting.resolve(
            firstDisplayID: "a", secondDisplayID: "b",
            isBuiltInByDisplayID: ["a": true, "A": false, "b": false]))
    }

    func testSidecarThirdDisplayDoesNotAffectPairRoles() {
        XCTAssertEqual(PairHybridRouting.resolve(
            firstDisplayID: "sidecar", secondDisplayID: "built-in",
            isBuiltInByDisplayID: [
                "built-in": true, "sidecar": false, "external": false
            ]),
            PairHybridRoute(builtInDisplayID: "built-in",
                            externalDisplayID: "sidecar"))
    }
}
