import CryptoKit
import XCTest
@testable import VibePulseAgents

private final class ParkedJobBox: @unchecked Sendable {
    var jobs: [ParkedRelayJob] = []
    var calls = 0
}

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
        XCTAssertEqual(snapshot.pairs.map(\.0), ["v", "seq", "agents"])
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

    func testModelLabelsAndProjectBasenames() {
        let labels = [
            "claude-opus-4-8": "OPUS 4.8",
            "claude-haiku-4-5-20251001": "HAIKU 4.5",
            "claude-3-7-sonnet-20250219": "SONNET 3.7",
            "gpt-4-0125-preview": "GPT-4 PREVIEW",
            "claude-mythos-preview": "MYTHOS PREVIEW",
            "gpt-5.4-mini": "GPT-5.4 MINI",
            "gpt-4o": "GPT-4O",
            "o4-mini": "O4 MINI",
            "codex-mini-latest": "CODEX MINI LATEST",
            "ft:gpt-4.1-mini-2025-04-14:acme::xyz": "GPT-4.1 MINI",
            "Claude-Opus-4-8 ": "OPUS 4.8",
            "gpt-5.6-sol": "GPT-5.6 SOL",
        ]
        for (model, label) in labels {
            XCTAssertEqual(normalizeModel(model), label, model)
        }
        XCTAssertEqual(sanitizeProject("Tor\u{00}get-med-ett-långt-namn"), "Torget-med-ett-l")
        XCTAssertEqual(sanitizeProject(String(repeating: "å", count: 16)), String(repeating: "å", count: 8))
        XCTAssertEqual(sanitizeProject("a/."), "a")
        XCTAssertEqual(sanitizeProject("/a/b/"), "b")
        XCTAssertEqual(sanitizeProject("a/.."), "..")
        XCTAssertNil(sanitizeProject("."))
        XCTAssertNil(sanitizeProject("/"))
    }

    func testStatuslinePeekNeverQuarantinesAndSummarizeDatesWindows() throws {
        let now = 1_790_000_000
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibepulse-statusline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sample = StatuslineSample.sampleURL(in: root)
        XCTAssertEqual(sample.lastPathComponent, StatuslineSample.sampleName)
        XCTAssertEqual(StatuslineSample.configURL(in: root).lastPathComponent, StatuslineSample.configName)
        XCTAssertEqual(StatuslineSample.freshSeconds, 900)

        let missing = StatuslineSample.peek(sample)
        XCTAssertEqual(missing.status, "missing")
        XCTAssertNil(missing.document)
        XCTAssertEqual(StatuslineSample.summarize(nil, now: now).status, "empty")

        try Data("{oops".utf8).write(to: sample)
        XCTAssertEqual(StatuslineSample.peek(sample).status, "invalid")
        XCTAssertEqual(try String(contentsOf: sample, encoding: .utf8), "{oops")

        try Data(#"{"v":2,"accounts":{}}"#.utf8).write(to: sample)
        XCTAssertEqual(StatuslineSample.peek(sample).status, "invalid")

        try Data(#"{"v":1,"accounts":{}}"#.utf8).write(to: sample)
        let empty = StatuslineSample.peek(sample)
        XCTAssertEqual(empty.status, "ok")
        XCTAssertEqual(StatuslineSample.summarize(empty.document, now: now).status, "empty")

        let five: [String: Any] = ["pct": 42.0, "resets_at": now + 100, "at": now - 10, "seen": now - 10]
        let week: [String: Any] = ["pct": 12.5, "resets_at": now + 86_400, "at": now - 3000, "seen": now - 3000]
        let freshBody: [String: Any] = ["v": 1, "accounts": ["single": [
            "five_hour": five, "seven_day": week, "claude_code_version": "2.1.0",
        ]]]
        try JSONSerialization.data(withJSONObject: freshBody).write(to: sample)
        let peeked = StatuslineSample.peek(sample)
        XCTAssertEqual(peeked.status, "ok")
        let summary = StatuslineSample.summarize(peeked.document, now: now)
        XCTAssertEqual(summary.status, "fresh")
        XCTAssertEqual(summary.ageS, 10)
        XCTAssertEqual(summary.claudeCodeVersion, "2.1.0")
        XCTAssertEqual(Set(summary.windows.keys), ["five_hour", "seven_day"])
        XCTAssertEqual(summary.windows["five_hour"]?.fresh, true)
        XCTAssertEqual(summary.windows["five_hour"]?.ageS, 10)
        XCTAssertEqual(summary.windows["five_hour"]?.pct, 42)
        XCTAssertEqual(summary.windows["seven_day"]?.fresh, false)
        XCTAssertEqual(summary.windows["seven_day"]?.ageS, 3000)

        let later = StatuslineSample.summarize(peeked.document, now: now + StatuslineSample.freshSeconds + 1)
        XCTAssertEqual(later.status, "stale")
        XCTAssertEqual(Array(later.windows.keys), ["seven_day"])

        let expired = StatuslineSample.summarize(peeked.document, now: now + 86_400)
        XCTAssertEqual(expired.status, "empty")
        XCTAssertNil(expired.ageS)
        XCTAssertEqual(expired.claudeCodeVersion, "2.1.0")
        XCTAssertTrue(expired.windows.isEmpty)

        let names = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(names.map(\.lastPathComponent), [StatuslineSample.sampleName])

        XCTAssertEqual(StatuslineSample.peek(root).status, "unreadable")
        let oversized = Data(count: StatuslineSample.sampleMaxBytes + 1)
        try oversized.write(to: sample)
        XCTAssertEqual(StatuslineSample.peek(sample).status, "invalid")
        XCTAssertEqual(try Data(contentsOf: sample), oversized)

        let versions: [Any] = [7, "", "a\nb", String(repeating: "x", count: 200)]
        for version in versions {
            let body: [String: Any] = ["v": 1, "accounts": ["single": [
                "five_hour": ["pct": 1, "resets_at": now + 100, "at": now, "seen": now],
                "claude_code_version": version,
            ]]]
            let data = try JSONSerialization.data(withJSONObject: body)
            let summarized = StatuslineSample.summarize(json: data, now: now)
            if version as? String == String(repeating: "x", count: 200) {
                XCTAssertEqual(summarized.claudeCodeVersion, String(repeating: "x", count: 64))
            } else {
                XCTAssertNil(summarized.claudeCodeVersion)
            }
            XCTAssertEqual(summarized.windows["five_hour"]?.fresh, true)
        }
        XCTAssertEqual(StatuslineSample.summarize(json: Data(#"{"v":1,"accounts":"x"}"#.utf8), now: now).status, "empty")
    }

    func testJSONLTailerResumesFromByteOffsetAndHoldsIncompleteLines() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("session.jsonl")
        let initial = Data("{\"first\":1}\n{\"half\":".utf8)
        try initial.write(to: path)
        let tailer = JsonlTailer()

        let first = tailer.read(path)
        XCTAssertEqual(first.records.count, 1)
        XCTAssertEqual((first.records[0] as? [String: Any])?["first"] as? Int, 1)
        XCTAssertTrue(first.caughtUp)
        XCTAssertEqual(tailer.byteOffset(of: path), UInt64(initial.count))

        let extra = Data("true}\n{\"second\":2}\n".utf8)
        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd()
        try handle.write(contentsOf: extra)
        try handle.close()

        let second = tailer.read(path)
        XCTAssertEqual(second.records.count, 2)
        XCTAssertEqual((second.records[0] as? [String: Any])?["half"] as? Bool, true)
        XCTAssertEqual((second.records[1] as? [String: Any])?["second"] as? Int, 2)
        XCTAssertEqual(tailer.byteOffset(of: path), UInt64(initial.count + extra.count))
        XCTAssertTrue(tailer.read(path).records.isEmpty)

        let messy = root.appendingPathComponent("messy.jsonl")
        try Data("not-json\n{\"valid\":true}\n".utf8).write(to: messy)
        let valid = tailer.read(messy)
        XCTAssertEqual(valid.records.count, 1)
        XCTAssertEqual((valid.records[0] as? [String: Any])?["valid"] as? Bool, true)

        let partialOnly = root.appendingPathComponent("partial.jsonl")
        let partial = Data("{\"only\":".utf8)
        try partial.write(to: partialOnly)
        let held = tailer.read(partialOnly)
        XCTAssertTrue(held.records.isEmpty)
        XCTAssertEqual(tailer.byteOffset(of: partialOnly), UInt64(partial.count))

        var body = Data()
        for index in 0..<257 {
            body.append(Data("{\"n\":\(index)}\n".utf8))
        }
        let many = root.appendingPathComponent("many.jsonl")
        try body.write(to: many)
        let batch = tailer.read(many)
        XCTAssertEqual(batch.records.count, JsonlTailer.maxRecordsPerPoll)
        XCTAssertFalse(batch.caughtUp)
        let rest = tailer.read(many)
        XCTAssertEqual(rest.records.count, 1)
        XCTAssertEqual((rest.records[0] as? [String: Any])?["n"] as? Int, 256)
        XCTAssertTrue(rest.caughtUp)

        let replaced = root.appendingPathComponent("replaced.jsonl")
        try Data("{\"old\":1}\n".utf8).write(to: replaced)
        XCTAssertEqual(tailer.read(replaced).records.count, 1)
        try Data("{\"a\":1}\n".utf8).write(to: replaced)
        let reread = tailer.read(replaced)
        XCTAssertEqual(reread.records.count, 1)
        XCTAssertEqual((reread.records[0] as? [String: Any])?["a"] as? Int, 1)
    }

    func testStartupReplayUsesEventTimestampsForBothClocks() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = root.appendingPathComponent("claude", isDirectory: true)
        let codex = root.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)

        let wall = Date().timeIntervalSince1970.rounded(.towardZero)
        let doneAt = wall - 2
        try writeJSONLines(claude.appendingPathComponent("old.jsonl"), [
            ["type": "user", "sessionId": "session-old", "uuid": "old-1",
             "cwd": "/Users/test/Torget", "timestamp": "2000-01-01T00:00:00Z"],
        ])
        try writeJSONLines(claude.appendingPathComponent("live.jsonl"), [
            ["type": "result", "subtype": "success", "sessionId": "session-live", "uuid": "done-1",
             "cwd": "/Users/test/Torget", "timestamp": iso8601(doneAt)],
            ["type": "user", "sessionId": "session-live", "uuid": "older-1",
             "cwd": "/Users/test/Torget", "timestamp": iso8601(doneAt - 3600)],
        ])
        let partial: [String: Any] = [
            "type": "user", "sessionId": "session-partial", "uuid": "partial-1",
            "cwd": "/Users/test/Torget", "timestamp": iso8601(doneAt),
        ]
        let partialData = try JSONSerialization.data(withJSONObject: partial)
        try partialData.write(to: claude.appendingPathComponent("partial.jsonl"))
        try writeJSONLines(codex.appendingPathComponent("rollout-old.jsonl"), [[
            "type": "event_msg", "timestamp": "2000-01-01T00:00:00Z",
            "payload": ["type": "task_started", "turn_id": "turn-old"],
        ]])

        let service = AgentStatusService(
            projectsDirectory: claude, codexSessions: codex, now: { 500 }, wall: { wall })
        XCTAssertEqual(service.pollOnce(), 3)
        let snapshot = service.snapshot()
        XCTAssertEqual(snapshot.int("v"), 2)
        XCTAssertEqual(snapshot.int("seq"), 3)
        let agents = try XCTUnwrap(snapshot.object("agents"))
        let claudeBody = try XCTUnwrap(agents.object("claude"))
        XCTAssertEqual(claudeBody.int("active_count"), 0)
        let jobs = try XCTUnwrap(claudeBody.array("jobs"))
        XCTAssertEqual(jobs.count, 1)
        guard case let .object(job) = jobs[0] else { return XCTFail("missing job") }
        XCTAssertEqual(job.string("state"), "done")
        XCTAssertEqual(job.int("updated_ms"), 2000)
        XCTAssertEqual(agents.object("codex")?.int("active_count"), 0)
        XCTAssertEqual(agents.object("codex")?.array("jobs")?.count, 0)
    }

    func testCodexNormalizationParksQuestionsAndShellPermissions() throws {
        XCTAssertEqual(posixShellTokens("make CC='touch /tmp/pwn' all"), ["make", "CC=touch /tmp/pwn", "all"])
        XCTAssertEqual(posixShellTokens("make \"all\""), ["make", "all"])
        XCTAssertEqual(posixShellTokens("echo \"a\\\"b\""), ["echo", "a\"b"])
        XCTAssertNil(posixShellTokens("make 'unterminated"))

        let question = try XCTUnwrap(normalizeCodexQuestion(
            payload: [
                "question": "Which auth approach?",
                "header": "Auth",
                "options": [
                    ["label": "Keep existing auth", "description": "Smaller change"],
                    ["label": "New auth layer", "description": "Cleaner architecture", "recommended": true],
                ],
            ],
            cwd: "/Users/niclas/vibepulse", sessionID: "session-123", turnID: "turn-456"))
        XCTAssertEqual(question.provider, "codex")
        XCTAssertEqual(question.recommendedIndex, 1)
        XCTAssertEqual(question.project, "vibepulse")
        XCTAssertEqual(stringValue(question.view, "prompt"), "Which auth approach?")
        XCTAssertEqual(stringValue(question.view, "title"), "New auth layer")
        XCTAssertEqual(boolValue(question.view, "can_approve"), true)

        let unmarked = try XCTUnwrap(normalizeCodexQuestion(
            payload: ["question": "Which?", "options": [["label": "A"], ["label": "B"]]],
            cwd: "/work/demo", sessionID: "s", turnID: "t"))
        XCTAssertNil(unmarked.recommendedIndex)
        XCTAssertEqual(boolValue(unmarked.view, "can_approve"), false)
        XCTAssertNil(normalizeCodexQuestion(
            payload: ["question": "Which?", "options": [["label": "A"]], "extra": true],
            cwd: "/work/demo", sessionID: "s", turnID: "t"))

        let store = InteractionStore(revealDetail: true, now: { 1_000 }, wall: { 50_000 })
        let requestID = try XCTUnwrap(store.park(question, holdSeconds: 30))
        let pending = try XCTUnwrap(store.pendingPublic())
        XCTAssertEqual(pending.pairs.map(\.0), [
            "request_id", "project", "expires_in_ms", "hold_ms", "provider", "kind", "options_total",
            "marked", "prompt", "can_approve", "title", "subtitle", "view_sha256",
        ])
        XCTAssertEqual(pending.string("provider"), "codex")
        XCTAssertEqual(pending.string("request_id"), requestID)
        let encoded = String(decoding: try JSONEncoder().encode(pending), as: UTF8.self)
        XCTAssertFalse(encoded.contains("session-123"))
        XCTAssertFalse(encoded.contains("turn-456"))
        XCTAssertFalse(encoded.contains("Auth"))

        let safe = [
            "make", "make all", "make ALL", "make \"all\"", "make test",
            "ninja", "ninja all", "ninja test",
            "cmake --build build", "cmake --build build --parallel 4",
            "cmake --build build --target all", "npm test", "npm run test",
            "npm run build", "npm run build --silent", "pytest",
            "python -m unittest", "cargo test", "cargo build", "go test",
            "ctest", "./test/run.sh", "idf.py build", "idf.py BUILD", "git status", "GIT status",
            "git log", "git show install", "git branch", "git branch --show-current",
            "git diff", "git diff --stat", "ls", "cat installer-notes.txt",
            "head README", "tail README", "wc README", "grep value README",
            "rg value README",
        ]
        let unsafe = [
            "npm run build -- --deploy", "git branch new-feature", "git branch -D old-feature",
            "git diff --output=result.patch", "make install-strip", "make -j4", "ninja -C build",
            "cmake --build build --output=result.patch", "cmake --build b --target install/strip",
            "npm install", "npm run deploy", "git diff --ext-diff", "git -c x=y status",
            "idf.py build flash", "./test/run.sh deploy", "./TEST/RUN.SH", "./Test/run.sh",
            "make CC='touch /tmp/pwn' all", "make CC='rm -f /tmp/pwn' build",
            "make ACTION=deploy all", "ninja CC='touch /tmp/pwn' all",
            "npm test; rm -rf build", "echo hi > notes.txt", "git push", "rm old.txt",
            "make 'unterminated", "git branch --Show-Current",
        ]
        for command in safe {
            XCTAssertEqual(shellCanApprove(command), true, command)
        }
        for command in unsafe {
            XCTAssertEqual(shellCanApprove(command), false, command)
        }
        XCTAssertEqual(shellCanApprove("git show install", reveal: false), false)
        XCTAssertEqual(permissionCanApprove(toolName: "Read", command: "cat README.md"), true)
        XCTAssertEqual(permissionCanApprove(toolName: "apply_patch", command: nil), false)
        XCTAssertNil(normalizeCodexPermission(event: ["hook_event_name": "PreToolUse"], reveal: true))

        let permissions = InteractionStore(revealDetail: true, now: { 1_000 }, wall: { 50_000 })
        let unsafeEvent = try XCTUnwrap(normalizeCodexPermission(event: permissionEvent("rm old.txt"), reveal: true))
        let unsafeID = try XCTUnwrap(permissions.park(unsafeEvent, holdSeconds: 30))
        XCTAssertEqual(permissions.pendingPublic()?.bool("can_approve"), false)
        XCTAssertNil(permissions.answer(requestID: unsafeID, verdict: "approve"))
        XCTAssertEqual(permissions.pendingPublic()?.string("request_id"), unsafeID)

        var forged = unsafeEvent
        forged.view = forged.view.map { key, value in
            key == "can_approve" ? (key, .bool(true)) : (key, value)
        }
        XCTAssertNil(permissions.park(forged, holdSeconds: 30))

        let safeEvent = try XCTUnwrap(normalizeCodexPermission(event: permissionEvent("git show install"), reveal: true))
        let safeID = try XCTUnwrap(permissions.park(safeEvent, holdSeconds: 30))
        XCTAssertEqual(safeEvent.view.first { $0.0 == "title" }?.1, .string("git show install"))
        XCTAssertEqual(boolValue(safeEvent.view, "can_approve"), true)
        XCTAssertFalse(safeID.isEmpty)
    }

    func testAnswerRejectsABadMACAndLeavesTheItemParked() throws {
        let secret = String(repeating: "a", count: 64)
        let store = InteractionStore(revealDetail: true, secret: secret, now: { 1_000 }, wall: { 50_000 })
        let question = try XCTUnwrap(normalizeCodexQuestion(
            payload: [
                "question": "Which auth approach?",
                "options": [
                    ["label": "Keep existing auth"],
                    ["label": "New auth layer", "description": "Cleaner architecture", "recommended": true],
                ],
            ],
            cwd: "/Users/niclas/vibepulse", sessionID: "session-123", turnID: "turn-456"))
        let requestID = try XCTUnwrap(store.park(question, holdSeconds: 120))
        let pending = try XCTUnwrap(store.pendingPublic())
        let digest = try XCTUnwrap(pending.string("view_sha256"))
        XCTAssertEqual(digest.count, 64)

        XCTAssertNil(store.answer(requestID: requestID, verdict: "approve"))
        XCTAssertNil(store.answer(requestID: requestID, verdict: "approve", mac: String(repeating: "0", count: 64), timestamp: 50_000))
        var wrongDigest = Array(digest)
        wrongDigest[0] = wrongDigest[0] == "a" ? "b" : "a"
        let rebound = signAnswerV2(
            secret: secret, provider: "codex", requestID: requestID, digest: String(wrongDigest),
            verdict: "approve", timestamp: 50_000)
        XCTAssertNil(store.answer(requestID: requestID, verdict: "approve", mac: rebound, timestamp: 50_000))
        let wrongProvider = signAnswerV2(
            secret: secret, provider: "claude", requestID: requestID, digest: digest,
            verdict: "approve", timestamp: 50_000)
        XCTAssertNil(store.answer(requestID: requestID, verdict: "approve", mac: wrongProvider, timestamp: 50_000))
        let stale = signAnswerV2(
            secret: secret, provider: "codex", requestID: requestID, digest: digest,
            verdict: "approve", timestamp: 50_000 + 91)
        XCTAssertNil(store.answer(requestID: requestID, verdict: "approve", mac: stale, timestamp: 50_091))
        XCTAssertEqual(store.pendingPublic()?.string("request_id"), requestID)

        let fresh = signAnswerV2(
            secret: secret, provider: "codex", requestID: requestID, digest: digest,
            verdict: "approve", timestamp: 50_000 + 90)
        let answer = try XCTUnwrap(store.answer(requestID: requestID, verdict: "approve", mac: fresh, timestamp: 50_090))
        XCTAssertEqual(answer.verdict, "approve")
        XCTAssertEqual(answer.optionIndex, 1)
        XCTAssertNil(store.pendingPublic())
    }

    func testParkLegacyOmitsTheV2BindingAndUsesV1HMAC() throws {
        let secret = String(repeating: "b", count: 32)
        let event = """
        {"cwd":"/work/bright-octopus","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which one?","options":[{"label":"Option A (recommended)","description":"desc"},{"label":"Option B"}]}]}}
        """
        let modern = InteractionStore(revealDetail: true, secret: secret, now: { 1_000 }, wall: { 50_000 })
        XCTAssertNotNil(modern.park(kind: "question", eventJSON: event, holdSeconds: 30))
        let modernPending = try XCTUnwrap(modern.pendingPublic())
        XCTAssertEqual(modernPending.string("provider"), "claude")
        XCTAssertEqual(modernPending.string("view_sha256")?.count, 64)

        let legacy = InteractionStore(revealDetail: true, secret: secret, now: { 1_000 }, wall: { 50_000 })
        let legacyParks = ParkedJobBox()
        legacy.setOnPark { legacyParks.jobs.append($0) }
        let requestID = try XCTUnwrap(legacy.parkLegacy(kind: "question", eventJSON: event, holdSeconds: 30))
        XCTAssertTrue(legacyParks.jobs.isEmpty)
        let pending = try XCTUnwrap(legacy.pendingPublic())
        XCTAssertEqual(pending.string("request_id"), requestID)
        XCTAssertNil(pending.value("provider"))
        XCTAssertNil(pending.value("view_sha256"))
        XCTAssertEqual(pending.string("kind"), "question")
        XCTAssertEqual(pending.bool("can_approve"), true)
        let job = try XCTUnwrap(legacy.relayJob(for: requestID))
        XCTAssertEqual(job.requestID, requestID)
        XCTAssertEqual(job.challenge.count, 32)
        XCTAssertEqual(job.canApprove, true)

        let v2Mac = signAnswerV2(
            secret: secret, provider: "claude", requestID: requestID,
            digest: SHA256.hash(data: job.canonicalViewBytes).map { String(format: "%02x", $0) }.joined(),
            verdict: "approve", timestamp: 50_000)
        XCTAssertNil(legacy.answer(requestID: requestID, verdict: "approve", mac: v2Mac, timestamp: 50_000))
        let stale = signAnswerV1(secret: secret, requestID: requestID, verdict: "approve", timestamp: 50_091)
        XCTAssertNil(legacy.answer(requestID: requestID, verdict: "approve", mac: stale, timestamp: 50_091))
        XCTAssertEqual(legacy.pendingPublic()?.string("request_id"), requestID)

        let fresh = signAnswerV1(secret: secret, requestID: requestID, verdict: "approve", timestamp: 50_000)
        let answer = try XCTUnwrap(legacy.answer(requestID: requestID, verdict: "approve", mac: fresh, timestamp: 50_000))
        XCTAssertEqual(answer.verdict, "approve")
        XCTAssertEqual(answer.optionIndex, 0)
        XCTAssertNil(legacy.pendingPublic())
        XCTAssertNil(legacy.relayJob(for: requestID))
    }

    func testRelayJobOnParkPanicAndAwaitVerdict() throws {
        let box = ParkedJobBox()
        let store = InteractionStore(revealDetail: true, now: { 1_000 }, wall: { 50_000 })
        store.setOnPark { box.jobs.append($0) }
        let event = """
        {"cwd":"/work/bright-octopus","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which one?","options":[{"label":"Option A (recommended)","description":"desc"},{"label":"Option B"}]}]}}
        """
        let requestID = try XCTUnwrap(store.park(kind: "question", eventJSON: event, holdSeconds: 30))
        let pending = try XCTUnwrap(store.pendingPublic())
        let job = try XCTUnwrap(store.relayJob(for: requestID))
        XCTAssertEqual(box.jobs, [job])
        XCTAssertEqual(job.challenge.count, 32)
        XCTAssertEqual(job.canApprove, true)
        XCTAssertEqual(job.canApprove, pending.bool("can_approve"))
        let digest = SHA256.hash(data: job.canonicalViewBytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, pending.string("view_sha256"))
        let text = String(decoding: job.canonicalViewBytes, as: UTF8.self)
        XCTAssertTrue(text.contains("\"request_id\":\"\(requestID)\""))
        XCTAssertTrue(text.contains("\"provider\":\"claude\""))
        XCTAssertTrue(text.contains("\"kind\":\"question\""))
        XCTAssertFalse(text.contains("expires_in_ms"))
        XCTAssertFalse(text.contains(": "))

        let second = try XCTUnwrap(store.park(kind: "approval", eventJSON: #"{"cwd":"/work/bright-octopus","tool_name":"Bash","tool_input":{"command":"rm old.txt"}}"#, holdSeconds: 30))
        XCTAssertEqual(box.jobs.count, 2)
        XCTAssertNotEqual(box.jobs[0].challenge, box.jobs[1].challenge)
        XCTAssertNil(store.park(kind: "nope", eventJSON: "{}", holdSeconds: 30))
        XCTAssertEqual(box.jobs.count, 2)

        let stored = expectation(description: "answer stored")
        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: 0.05)
            _ = store.answer(requestID: requestID, verdict: "approve")
            stored.fulfill()
        }
        let approved = store.awaitVerdict(requestID: requestID, timeout: 2)
        wait(for: [stored], timeout: 2)
        XCTAssertEqual(approved?.verdict, "approve")
        XCTAssertEqual(approved?.optionIndex, 0)
        XCTAssertNil(store.awaitVerdict(requestID: requestID, timeout: 0))

        XCTAssertNil(store.answer(requestID: second, verdict: "approve"))
        XCTAssertNil(store.awaitVerdict(requestID: second, timeout: 0))
        XCTAssertEqual(store.pendingPublic()?.string("request_id"), second)

        let denied = expectation(description: "panic stored")
        let panicCount = ParkedJobBox()
        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: 0.05)
            panicCount.calls = store.panic()
            denied.fulfill()
        }
        let panicResult = store.awaitVerdict(requestID: second, timeout: 2)
        wait(for: [denied], timeout: 2)
        XCTAssertEqual(panicCount.calls, 1)
        XCTAssertEqual(panicResult?.verdict, "deny")
        XCTAssertNil(panicResult?.optionIndex)
        XCTAssertNil(store.pendingPublic())
        XCTAssertEqual(store.panic(), 0)
        XCTAssertNil(store.awaitVerdict(requestID: "missing", timeout: 0.05))
    }

    func testStopEndsPollOnceLoopsAndLeavesTheAgentWireAlone() throws {
        let service = AgentStatusService(now: { 5_000 })
        XCTAssertTrue(try service.applyLine(claudeUser, provider: "claude"))
        let beforeShot = service.snapshot()
        XCTAssertEqual(beforeShot.pairs.map(\.0), ["v", "seq", "agents"])
        XCTAssertEqual(beforeShot.int("v"), 2)
        XCTAssertEqual(beforeShot.int("seq"), 1)

        let first = expectation(description: "first poll loop")
        let second = expectation(description: "second poll loop")
        DispatchQueue.global().async {
            service.pollOnceLoop(interval: 30)
            first.fulfill()
        }
        DispatchQueue.global().async {
            service.pollOnceLoop(interval: 30)
            second.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.05)
        service.stop()
        wait(for: [first, second], timeout: 2)
        service.stop()
        XCTAssertEqual(service.snapshot(), beforeShot)
        service.pollOnceLoop(interval: 30)
        XCTAssertEqual(service.pollOnce(), 0)
    }

    func testReadDeviceKeyIsNilWhenTheFileIsAbsent() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibepulse-missing-device-key-\(UUID().uuidString)")
        XCTAssertNil(readDeviceKey(at: missing))

        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appendingPathComponent("empty")
        try Data().write(to: empty)
        XCTAssertNil(readDeviceKey(at: empty))
        let blank = root.appendingPathComponent("blank")
        try Data(" \n\t".utf8).write(to: blank)
        XCTAssertNil(readDeviceKey(at: blank))
        let present = root.appendingPathComponent("key")
        try Data("  device-key \n".utf8).write(to: present)
        XCTAssertEqual(readDeviceKey(at: present), "device-key")
        let broken = root.appendingPathComponent("broken")
        try Data([0xFF]).write(to: broken)
        XCTAssertNil(readDeviceKey(at: broken))
    }

    func testPendingPublicDropsAnItemThatExceedsTheWireCap() throws {
        let marks = String(repeating: "é", count: 48)
        let title = String(repeating: "é", count: 32)
        let event = """
        {"cwd":"/work/p","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"\(marks)","options":[{"label":"\(title) (recommended)","description":"\(title)"},{"label":"B"}]}]}}
        """
        let store = InteractionStore(revealDetail: true, now: { 1_000 })
        XCTAssertNotNil(store.park(kind: "question", eventJSON: event, holdSeconds: 30))
        XCTAssertNil(store.pendingPublic())
    }

    private func signAnswerV1(secret: String, requestID: String, verdict: String, timestamp: Int) -> String {
        let message = Data("\(requestID)|\(verdict)|\(timestamp)".utf8)
        let code = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: Data(secret.utf8)))
        return code.map { String(format: "%02x", $0) }.joined()
    }

    private func shellCanApprove(_ command: String, reveal: Bool = true) -> Bool {
        permissionCanApprove(toolName: "Shell", command: command, reveal: reveal)
    }

    private func permissionCanApprove(toolName: String, command: String?, reveal: Bool = true) -> Bool {
        var input: [String: Any] = [:]
        if let command { input["command"] = command }
        let normalized = normalizeCodexPermission(event: [
            "hook_event_name": "PermissionRequest",
            "session_id": "session-123",
            "turn_id": "turn-456",
            "cwd": "/Users/niclas/vibepulse",
            "tool_name": toolName,
            "tool_input": input,
        ], reveal: reveal)
        return normalized.flatMap { boolValue($0.view, "can_approve") } ?? false
    }

    private func permissionEvent(_ command: String) -> [String: Any] {
        [
            "hook_event_name": "PermissionRequest",
            "session_id": "session-123",
            "turn_id": "turn-456",
            "cwd": "/Users/niclas/vibepulse",
            "tool_name": "Shell",
            "tool_input": ["command": command],
        ]
    }

    private func stringValue(_ pairs: [(String, WireValue)], _ key: String) -> String? {
        guard case let .string(value) = pairs.first(where: { $0.0 == key })?.1 else { return nil }
        return value
    }

    private func boolValue(_ pairs: [(String, WireValue)], _ key: String) -> Bool? {
        guard case let .bool(value) = pairs.first(where: { $0.0 == key })?.1 else { return nil }
        return value
    }

    private func makeTempDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibepulse-agents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeJSONLines(_ url: URL, _ records: [[String: Any]]) throws {
        var data = Data()
        for record in records {
            data.append(try JSONSerialization.data(withJSONObject: record))
            data.append(0x0A)
        }
        try data.write(to: url)
    }

    private func iso8601(_ seconds: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    private func states(in agents: [String: Any], provider: String) -> [String] {
        let body = agents[provider] as? [String: Any]
        let jobs = body?["jobs"] as? [[String: Any]] ?? []
        return jobs.compactMap { $0["state"] as? String }
    }
}
