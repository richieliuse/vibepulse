import XCTest
@testable import VibePulseBarCore

func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

final class ParsingTests: XCTestCase {
    func testLiveTokensKeepNullsAsMissing() throws {
        let tokens = try XCTUnwrap(TokensSnapshot(data: fixture("tokens-live.json")))
        XCTAssertNil(tokens.claudeWeek.usedPercent, "a null quota must stay a dash, never 0")
        XCTAssertFalse(tokens.claudeWeek.hasData)
        XCTAssertEqual(tokens.codexWeek.usedPercent, 32)
        XCTAssertEqual(tokens.codexWeek.resetMinutes, 9483)
        XCTAssertEqual(tokens.codexForecast.state, .exhausts)
        XCTAssertEqual(tokens.codexForecast.offsetMinutes, -7499)
        XCTAssertEqual(tokens.grokCredit.usedPercent, 94)
        XCTAssertEqual(tokens.grokQuotaLabel, "WEEKLY")
        XCTAssertEqual(tokens.cursorBot.resetMinutes, 613)
        XCTAssertEqual(tokens.usageTotals?.state, "ready")
        XCTAssertEqual(tokens.usageTotals?.placeholder, false)
        XCTAssertNil(tokens.value?.multiple)
    }

    func testRejectsOtherWireVersions() {
        XCTAssertNil(TokensSnapshot(data: Data(#"{"v": 1, "dayTokens": 3}"#.utf8)))
        XCTAssertNil(TokensSnapshot(data: Data("not json".utf8)))
        XCTAssertNil(AgentStatusSnapshot(data: Data(#"{"v": 1, "agents": {}}"#.utf8)))
    }

    func testFullTokens() throws {
        let tokens = try XCTUnwrap(TokensSnapshot(data: fixture("tokens-full.json")))
        XCTAssertEqual(tokens.claudeSession.usedPercent, 42)
        XCTAssertEqual(tokens.claudeModelWeekLabel, "FABLE · WEEK")
        XCTAssertEqual(tokens.claudeForecast.state, .atReset)
        XCTAssertEqual(tokens.claudeForecast.pctAtReset, 88)
        XCTAssertEqual(tokens.dayTokens, 48_213_000)
        XCTAssertEqual(tokens.value?.multiple, 9.2)
        XCTAssertTrue(tokens.volumeIsMeasured)
    }

    func testAgentStatusSortsByAttention() throws {
        let agents = try XCTUnwrap(AgentStatusSnapshot(data: fixture("agent-status.json")))
        XCTAssertEqual(agents.claude.activeCount, 2)
        XCTAssertEqual(agents.claude.jobs.first?.state, .waiting, "whoever needs the user comes first")
        XCTAssertEqual(agents.claude.waitingCount, 1)
        XCTAssertEqual(agents.codex.jobs.first?.state, .working)
        XCTAssertEqual(agents.codex.jobs.first?.model, "GPT-6 SOL")
        XCTAssertEqual(agents.totalWaiting, 1)
        XCTAssertEqual(agents.totalActive, 3)
        XCTAssertNil(agents.agents(for: .grok))
    }

    func testJobAgeProjectsFromFetchTime() {
        let job = AgentJob(taskID: "t", state: .working, updatedMilliseconds: 5_400)
        let fetched = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(job.ageSeconds(fetchedAt: fetched, now: fetched.addingTimeInterval(10)), 15)
        XCTAssertNil(AgentJob(taskID: "t", state: .idle).ageSeconds(fetchedAt: fetched, now: fetched))
        XCTAssertEqual(AgentJob(taskID: "t", state: .waiting, activity: "waiting_input").activityText,
                       "waiting input")
    }

    func testDiagnostics() throws {
        let diagnostics = try XCTUnwrap(ServerDiagnostics(data: fixture("diagnostics.json")))
        XCTAssertTrue(diagnostics.isTokenServer)
        XCTAssertEqual(diagnostics.rev, "81c8f46")
        XCTAssertNotNil(diagnostics.startedAt)
        XCTAssertEqual(diagnostics.probes[.codex]?.isHealthy, true)
        XCTAssertEqual(diagnostics.probes[.codex]?.ageSeconds, 1262)
        XCTAssertEqual(diagnostics.probes[.claude]?.isHealthy, false)
        XCTAssertEqual(diagnostics.claudeCredentialStatus, "unavailable")
        XCTAssertEqual(diagnostics.panel?.status, "stale")
        XCTAssertEqual(diagnostics.panel?.ageSeconds, 9847)
        XCTAssertEqual(diagnostics.discoveryStatus, "ready")
    }

    func testForeignServiceIsNotATokenServer() throws {
        let other = try XCTUnwrap(ServerDiagnostics(data: Data(#"{"service": "something-else"}"#.utf8)))
        XCTAssertFalse(other.isTokenServer)
    }
}
