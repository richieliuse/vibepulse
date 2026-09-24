import XCTest
@testable import VibePulseAgents

final class AgentTests: XCTestCase {
    private let claudeUser = #"{"type":"user","sessionId":"session-1","uuid":"event-1","cwd":"/Users/test/Torget"}"#
    private let claudeDone = #"{"type":"result","subtype":"success","sessionId":"session-2","uuid":"event-2","cwd":"/Users/test/Torget"}"#
    private let claudeWaiting = #"{"type":"assistant","sessionId":"session-3","uuid":"event-3","cwd":"/Users/test/Torget","message":{"content":[{"type":"tool_use","name":"AskUserQuestion","input":{}}]}}"#
    private let codexDone = #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}"#
    private let codexWorking = #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-2"}}"#

    func testClassifyClaudeAndCodexLinesIntoJobStates() throws {
        let user = classifyClaudeLine(claudeUser)
        XCTAssertEqual(user?.state, "working")
        XCTAssertEqual(user?.activity, "thinking")
        XCTAssertEqual(user?.project, "Torget")

        let done = classifyClaudeLine(claudeDone)
        XCTAssertEqual(done?.state, "done")
        XCTAssertNil(done?.activity)

        let waiting = classifyClaudeLine(claudeWaiting)
        XCTAssertEqual(waiting?.state, "waiting")
        XCTAssertEqual(waiting?.activity, "waiting_input")

        XCTAssertEqual(classifyCodexLine(codexWorking)?.state, "working")
        XCTAssertEqual(classifyCodexLine(codexDone)?.state, "done")

        let service = AgentStatusService(now: { 5_000 })
        XCTAssertTrue(try service.applyLine(claudeUser, provider: "claude"))
        XCTAssertTrue(try service.applyLine(claudeDone, provider: "claude"))
        XCTAssertTrue(try service.applyLine(claudeWaiting, provider: "claude"))
        XCTAssertTrue(try service.applyLine(codexWorking, provider: "codex"))
        XCTAssertTrue(try service.applyLine(codexDone, provider: "codex"))

        let snapshot = service.snapshot()
        let data = try JSONEncoder().encode(snapshot)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["v"] as? Int, 2)
        XCTAssertEqual(root["seq"] as? Int, 5)
        let agents = try XCTUnwrap(root["agents"] as? [String: Any])
        XCTAssertEqual(states(in: agents, provider: "claude"), ["waiting", "working", "done"])
        XCTAssertEqual(states(in: agents, provider: "codex"), ["working", "done"])

        let claudeJobs = try XCTUnwrap(snapshot.object("agents")?.object("claude")?.array("jobs"))
        guard case let .object(first) = claudeJobs[0] else { return XCTFail("missing job") }
        XCTAssertEqual(first.string("state"), "waiting")
        XCTAssertEqual(first.string("activity"), "waiting_input")
        XCTAssertEqual(first.string("project"), "Torget")
        XCTAssertEqual(snapshot.object("agents")?.object("codex")?.int("active_count"), 1)
    }

    func testInteractionResultRejectsBadVerdicts() {
        XCTAssertThrowsError(try InteractionResult(verdict: "yes"))
        XCTAssertThrowsError(try InteractionResult(verdict: "approve", optionIndex: -1))
        XCTAssertEqual(InteractionProvider.claude.rawValue, "claude")
        XCTAssertNil(InteractionProvider(rawValue: "CODEX"))
    }

    func testParkAnswerAndPendingPublic() throws {
        let store = InteractionStore(revealDetail: true, now: { 1_000 })
        let event = """
        {"cwd":"/work/bright-octopus","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which one?","options":[{"label":"Option A (recommended)","description":"desc"},{"label":"Option B"}]}]}}
        """
        let requestID = try XCTUnwrap(store.park(kind: "question", eventJSON: event, holdSeconds: 30))
        let pending = try XCTUnwrap(store.pendingPublic())
        XCTAssertEqual(pending.string("request_id"), requestID)
        XCTAssertEqual(pending.string("provider"), "claude")
        XCTAssertEqual(pending.string("kind"), "question")
        XCTAssertEqual(pending.string("project"), "bright-octopus")
        XCTAssertEqual(pending.bool("can_approve"), true)
        XCTAssertEqual(pending.int("hold_ms"), 30_000)
        XCTAssertEqual(pending.string("view_sha256")?.count, 64)

        let digest = viewDigest(pending.pairs.filter { $0.0 != "view_sha256" && $0.0 != "expires_in_ms" })
        XCTAssertEqual(digest, pending.string("view_sha256"))
        XCTAssertEqual(
            canonicalJSONObject(["provider": .string("claude"), "title": .string("Fråga")]),
            "{\"provider\":\"claude\",\"title\":\"Fråga\"}")

        let answer = try XCTUnwrap(store.answer(requestID: requestID, verdict: "approve"))
        XCTAssertEqual(answer.verdict, "approve")
        XCTAssertEqual(answer.optionIndex, 0)
        XCTAssertNil(store.pendingPublic())
    }

    private func states(in agents: [String: Any], provider: String) -> [String] {
        let body = agents[provider] as? [String: Any]
        let jobs = body?["jobs"] as? [[String: Any]] ?? []
        return jobs.compactMap { $0["state"] as? String }
    }
}
