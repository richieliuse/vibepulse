import XCTest
@testable import VibePulseServer

final class EngineHTTPTests: XCTestCase {
    func testTokensRouteHonorsUsageTotalsHeader() throws {
        let engine = VibePulseEngine(port: 0)
        engine.tokensJSON = [
            "v": 2,
            "dayTokens": 0,
            "usageTotals": ["state": "refreshing", "placeholder": true, "sinceS": 1],
        ]
        let denied = engine.response(method: "GET", path: "/api/tokens", headers: [:])
        XCTAssertEqual(denied.status, 503)
        let accepted = engine.response(
            method: "GET", path: "/api/tokens",
            headers: ["x-vibepulse-accepts": "usage-totals"])
        XCTAssertEqual(accepted.status, 200)
        let served = try JSONSerialization.jsonObject(with: accepted.body) as? [String: Any]
        XCTAssertEqual(served?["v"] as? Int, 2)
    }

    func testUnknownRouteIs404() {
        let engine = VibePulseEngine(port: 0)
        XCTAssertEqual(engine.response(method: "GET", path: "/nope", headers: [:]).status, 404)
        XCTAssertEqual(engine.response(method: "POST", path: "/api/tokens", headers: [:]).status, 404)
    }
}
