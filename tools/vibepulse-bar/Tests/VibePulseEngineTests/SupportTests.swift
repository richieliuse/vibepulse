import XCTest
@testable import VibePulseSupport

final class SupportTests: XCTestCase {
    func testBoolIsNotANumber() {
        let parsed = StrictJSON.parse(Data("{\"n\":true,\"i\":1,\"d\":1.5}".utf8))
        guard case let .success(.object(object)) = parsed else {
            return XCTFail("\(parsed)")
        }
        XCTAssertEqual(object["n"], .bool(true))
        XCTAssertNil(object["n"]?.number)
        XCTAssertEqual(object["i"]?.int, 1)
        XCTAssertEqual(object["d"]?.number, 1.5)
    }

    func testQuotaIdentityIsStable() {
        let id = StateFiles.quotaIdentity(provider: "claude", scope: "general_weekly")
        XCTAssertEqual(id.count, 64)
        XCTAssertEqual(id, StateFiles.quotaIdentity(provider: "claude", scope: "general_weekly"))
        XCTAssertNotEqual(id, StateFiles.quotaIdentity(provider: "claude", scope: "model_weekly"))
    }
}
