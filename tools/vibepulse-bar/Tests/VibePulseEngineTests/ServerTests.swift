import CryptoKit
import Darwin
import Foundation
import XCTest
import VibePulseAgents
import VibePulseProviders
import VibePulseRelay
import VibePulseState
import VibePulseSupport
@testable import VibePulseServer

final class ServerTests: XCTestCase {
    private let stopOrder = [
        "discovery", "interaction-relay", "numbers-publisher", "github",
        "backfill", "max-tracker-save", "agent-status", "listener",
    ]

    func testDefaultsStayOffTheLivePort() {
        XCTAssertEqual(VibePulseEngine.defaultPort, 8737)
        XCTAssertEqual(VibePulseEngine.defaultConnectionCap, 32)
        let engine = VibePulseEngine()
        XCTAssertEqual(engine.port, 8737)
        XCTAssertEqual(engine.workerRuns.values.reduce(0, +), 0)
    }

    func testPlaceholderStaysNullAndUnderTheFirmwareCap() throws {
        let engine = VibePulseEngine(port: 0)
        let denied = engine.response(method: "GET", path: "/api/tokens", headers: [:])
        XCTAssertEqual(denied.status, 503)
        let deniedText = try text(denied.body)
        XCTAssertEqual(deniedText, "{\"error\":\"usage totals not measured yet\",\"usageTotals\":{\"state\":\"refreshing\",\"sinceS\":0,\"placeholder\":true}}")
        XCTAssertFalse(deniedText.contains("dayTokens"))

        let accepted = engine.response(
            method: "GET", path: "/api/tokens",
            headers: ["X-VibePulse-Accepts": "agent-rows, USAGE-TOTALS"])
        XCTAssertEqual(accepted.status, 200)
        let body = try text(accepted.body)
        XCTAssertLessThan(body.utf8.count, VibePulseEngine.tokensBodyCap)
        XCTAssertTrue(body.contains("\"claudeSessionPct\":null"))
        XCTAssertTrue(body.contains("\"grokCreditPct\":null"))
        XCTAssertTrue(body.contains("\"codexWeekPct\":null"))
        XCTAssertTrue(body.contains("\"placeholder\":true"))
        XCTAssertTrue(body.contains("\"claudeWeekStale\":false"))
        XCTAssertFalse(body.contains("\"claudeSessionPct\":0"))
        XCTAssertFalse(body.contains("\"claudeWeekStale\":0"))
        XCTAssertFalse(body.contains("\"grokCreditStale\":0"))

        let ignored = engine.response(
            method: "GET", path: "/api/tokens",
            headers: ["x-vibepulse-accepts": "something-else"])
        XCTAssertEqual(ignored.status, 503)

        for (path, cap) in [
            ("/api/max-tracker", VibePulseEngine.maxTrackerBodyCap),
            ("/api/github", VibePulseEngine.githubBodyCap),
            ("/api/agent-status", VibePulseEngine.agentStatusBodyCap),
        ] {
            let response = engine.response(method: "GET", path: path, headers: [:])
            XCTAssertEqual(response.status, 200, path)
            XCTAssertLessThan(response.body.count, cap, path)
        }
        let github = try text(engine.response(method: "GET", path: "/api/github", headers: [:]).body)
        XCTAssertEqual(github, "{\"v\":1,\"enabled\":false}")
    }

    func testMenuSnapshotDoesNotPublishPeaks() throws {
        let engine = VibePulseEngine(port: 0)
        let day = engine.localDay(Date().timeIntervalSince1970)
        engine.tokensJSON = [
            "v": 2,
            "dayTokens": 3,
            "usageTotals": ["state": "ready", "placeholder": false, "ageS": 1],
            "claudeSessionPct": 40.0,
            "claudeWeekStale": false,
        ]
        _ = engine.snapshot
        XCTAssertNil(engine.maxTracker.snapshot(today: day).claude.avgPeakPct)

        let boolPct = VibePulseEngine(port: 0)
        boolPct.tokensJSON = [
            "v": 2,
            "dayTokens": 3,
            "usageTotals": ["state": "ready", "placeholder": false, "ageS": 1],
            "claudeSessionPct": true,
        ]
        _ = boolPct.response(
            method: "GET", path: "/api/tokens",
            headers: ["x-vibepulse-accepts": "usage-totals"])
        XCTAssertNil(boolPct.maxTracker.snapshot(today: day).claude.avgPeakPct)

        let served = engine.response(
            method: "GET", path: "/api/tokens",
            headers: ["x-vibepulse-accepts": "usage-totals"])
        XCTAssertEqual(served.status, 200)
        XCTAssertLessThan(served.body.count, VibePulseEngine.tokensBodyCap)
        XCTAssertEqual(engine.maxTracker.snapshot(today: day).claude.avgPeakPct, 40)
        _ = engine.snapshot
        XCTAssertEqual(engine.maxTracker.snapshot(today: day).claude.avgPeakPct, 40)
    }

    func testRoutesAndPostGateOrder() throws {
        let idle = VibePulseEngine(port: 0)
        XCTAssertEqual(idle.response(method: "GET", path: "/api/tokens?x=1", headers: [:]).status, 404)
        XCTAssertEqual(idle.response(method: "GET", path: "/api/tokens/", headers: [:]).status, 404)
        XCTAssertEqual(idle.response(method: "GET", path: "/nope", headers: ["host": "attacker.example"]).status, 404)
        XCTAssertEqual(idle.response(method: "HEAD", path: "/api/tokens", headers: [:]).status, 501)
        let unknown = idle.response(method: "POST", path: "/api/tokens", headers: ["content-type": "application/json"])
        XCTAssertEqual(unknown.status, 404)
        XCTAssertEqual(try text(unknown.body), "{\"error\":\"interactions are not enabled\"}")
        XCTAssertEqual(idle.jsonBodyReads, 0)

        var env = EngineEnvironment()
        env.claudeInteractions = true
        env.codexInteractions = false
        env.interactionTimeout = 0.05
        let engine = VibePulseEngine(port: 0, environment: env)
        let event = Data("{\"nope\":true}".utf8)
        let headers = [
            "content-type": "application/json",
            "content-length": "\(event.count)",
            "host": "localhost",
        ]

        let disabledCodex = engine.response(
            method: "POST", path: "/api/codex/question", headers: headers, body: event, peer: "127.0.0.1")
        XCTAssertEqual(disabledCodex.status, 404)
        XCTAssertEqual(engine.jsonBodyReads, 0)

        let remote = engine.response(
            method: "POST", path: "/api/hook/question", headers: headers, body: event, peer: "10.0.0.5")
        XCTAssertEqual(remote.status, 403)
        XCTAssertEqual(try text(remote.body), "{\"error\":\"hooks must be local\"}")

        var badHost = headers
        badHost["host"] = "attacker.example"
        let rebinding = engine.response(
            method: "POST", path: "/api/hook/permission", headers: badHost, body: event, peer: "127.0.0.1")
        XCTAssertEqual(rebinding.status, 403)
        XCTAssertEqual(try text(rebinding.body), "{\"error\":\"hook ingress rejected\"}")

        var origin = headers
        origin["origin"] = "null"
        let originated = engine.response(
            method: "POST", path: "/api/hook/question", headers: origin, body: event, peer: "127.0.0.1")
        XCTAssertEqual(originated.status, 403)

        var plain = headers
        plain["content-type"] = "text/plain"
        let media = engine.response(
            method: "POST", path: "/api/hook/question", headers: plain, body: event, peer: "127.0.0.1")
        XCTAssertEqual(media.status, 415)
        XCTAssertEqual(engine.jsonBodyReads, 0)

        let answerTooSoon = idle.response(
            method: "POST", path: "/api/interaction/abc",
            headers: ["host": "10.0.0.8"], body: event, peer: "192.168.1.20")
        XCTAssertEqual(answerTooSoon.status, 404)

        let answerType = engine.response(
            method: "POST", path: "/api/interaction/abc",
            headers: ["host": "10.0.0.8"], body: event, peer: "192.168.1.20")
        XCTAssertEqual(answerType.status, 415)
        XCTAssertEqual(engine.jsonBodyReads, 0)

        let badAnswer = engine.response(
            method: "POST", path: "/api/interaction/abc",
            headers: headers, body: event, peer: "192.168.1.20")
        XCTAssertEqual(badAnswer.status, 400)
        XCTAssertEqual(engine.jsonBodyReads, 1)

        let panicBody = Data("{\"ts\":1}".utf8)
        var panicHeaders = headers
        panicHeaders["content-length"] = "\(panicBody.count)"
        let panic = engine.response(
            method: "POST", path: "/api/panic",
            headers: panicHeaders, body: panicBody, peer: "192.168.1.9")
        XCTAssertEqual(panic.status, 200)
        XCTAssertEqual(try text(panic.body), "{\"ok\":true,\"denied\":0}")

        var codexEnv = EngineEnvironment()
        codexEnv.codexInteractions = true
        let codexEngine = VibePulseEngine(port: 0, environment: codexEnv)
        let codexBody = Data("{\"cwd\":\"/work/demo\",\"session_id\":\"s\",\"turn_id\":\"t\",\"question\":\"Which?\",\"options\":[{\"label\":\"A\"},{\"label\":\"B\"}],\"extra\":1}".utf8)
        let codex = codexEngine.response(
            method: "POST", path: "/api/codex/question",
            headers: [
                "content-type": "application/json",
                "content-length": "\(codexBody.count)",
                "host": "localhost",
            ],
            body: codexBody, peer: "127.0.0.1")
        XCTAssertEqual(codex.status, 200)
        XCTAssertEqual(try text(codex.body), "{\"status\":\"computer\",\"reason\":\"invalid\"}")
        XCTAssertNil(codexEngine.interactionStore?.pendingPublic())

        let missing = engine.response(method: "POST", path: "/api/nowhere", headers: headers, body: event)
        XCTAssertEqual(missing.status, 404)
        XCTAssertEqual(try text(missing.body), "{\"error\":\"not found\"}")
    }

    func testAnswerPublishesRelayRemoval() throws {
        let token = InteractionRelayCrypto.b64URLEncode(Data(repeating: 0x11, count: 32))
        let calls = RelayCapture()
        var env = EngineEnvironment()
        env.claudeInteractions = true
        env.interactionTimeout = 2
        env.automaticWorkers = false
        env.relay = EngineRelayConfig(
            baseURL: "https://relay.example/",
            mailbox: "vp_A1b2C3d4E5f6G7h8",
            macToken: token,
            deviceKeyHex: String(repeating: "ab", count: 32),
            transport: { try calls.send($0) }
        )
        let engine = VibePulseEngine(port: 0, environment: env)
        let event = #"{"cwd":"/work/bright-octopus","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which one?","options":[{"label":"Option A (recommended)","description":"desc"},{"label":"Option B"}]}]}}"#
        let body = Data(event.utf8)
        let parked = expectation(description: "hook returned")
        let box = ResponseBox()
        DispatchQueue.global().async {
            box.response = engine.response(
                method: "POST", path: "/api/hook/question",
                headers: [
                    "content-type": "application/json",
                    "content-length": "\(body.count)",
                    "host": "127.0.0.1",
                ],
                body: body, peer: "127.0.0.1")
            parked.fulfill()
        }
        let requestID = try waitForRequest(engine)
        let relayBefore = try XCTUnwrap(engine.bridge?.relay)
        XCTAssertGreaterThanOrEqual(relayBefore.publishQueueSize, 1)
        let verdict = Data("{\"verdict\":\"deny\"}".utf8)
        let answer = engine.response(
            method: "POST", path: "/api/interaction/\(requestID)",
            headers: [
                "content-type": "application/json",
                "content-length": "\(verdict.count)",
            ],
            body: verdict, peer: "192.168.1.40")
        XCTAssertEqual(answer.status, 200)
        XCTAssertEqual(try text(answer.body), "{\"ok\":true,\"reason\":\"ok\"}")
        wait(for: [parked], timeout: 3)
        let hook = try XCTUnwrap(box.response)
        XCTAssertEqual(hook.status, 200)
        XCTAssertTrue(try text(hook.body).contains("\"permissionDecision\":\"deny\""))
        let relay = try XCTUnwrap(engine.bridge?.relay)
        XCTAssertGreaterThanOrEqual(relay.publishQueueSize, 2)
        XCTAssertNil(engine.interactionStore?.pendingPublic())
    }

    func testPendingFitsAndOversizedPendingIsLeftOut() throws {
        let engine = VibePulseEngine(port: 0, environment: {
            var env = EngineEnvironment()
            env.claudeInteractions = true
            return env
        }())
        let event = #"{"cwd":"/work/bright-octopus","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which one?","options":[{"label":"Option A (recommended)","description":"desc"},{"label":"Option B"}]}]}}"#
        XCTAssertNotNil(engine.interactionStore?.park(kind: "question", eventJSON: event, holdSeconds: 30))
        let status = engine.response(method: "GET", path: "/api/agent-status", headers: [:])
        let body = try text(status.body)
        XCTAssertLessThan(body.utf8.count, VibePulseEngine.agentStatusBodyCap)
        XCTAssertTrue(body.contains("\"pending\":"))
        XCTAssertTrue(body.hasPrefix("{\"v\":2,\"seq\":"))
        XCTAssertTrue(body.contains("\"agents\":"))
        XCTAssertFalse(body.contains("\"error\""))

        let marks = String(repeating: "é", count: 48)
        let title = String(repeating: "é", count: 32)
        let huge = """
        {"cwd":"/work/p","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"\(marks)","options":[{"label":"\(title) (recommended)","description":"\(title)"},{"label":"B"}]}]}}
        """
        let quiet = VibePulseEngine(port: 0, environment: {
            var env = EngineEnvironment()
            env.claudeInteractions = true
            env.interactionDetail = true
            return env
        }())
        XCTAssertNotNil(quiet.interactionStore?.park(kind: "question", eventJSON: huge, holdSeconds: 30))
        XCTAssertNil(quiet.interactionStore?.pendingPublic())
        let plain = try text(quiet.response(method: "GET", path: "/api/agent-status", headers: [:]).body)
        XCTAssertFalse(plain.contains("\"pending\""))
        XCTAssertLessThan(plain.utf8.count, VibePulseEngine.agentStatusBodyCap)
    }

    func testPanelConfirmationIgnoresLoopback() throws {
        let clock = FixedClock(wall: 1_700_000_000, monotonic: 1_000)
        var env = EngineEnvironment()
        env.clock = clock
        let engine = VibePulseEngine(port: 0, environment: env)
        _ = engine.response(method: "GET", path: "/api/github", headers: [:], peer: "127.0.0.1")
        _ = engine.response(method: "GET", path: "/api/github", headers: [:], peer: "192.168.1.20")
        var waiting = try json(engine.response(method: "GET", path: "/", headers: [:]).body)
        XCTAssertEqual(waiting["interactions"] as? [String: Any] == nil, false)
        let interactions = try XCTUnwrap(waiting["interactions"] as? [String: Any])
        let panel = try XCTUnwrap(interactions["panel"] as? [String: Any])
        XCTAssertEqual(panel["status"] as? String, "waiting")

        _ = engine.response(
            method: "GET", path: "/api/agent-status",
            headers: ["x-vibepulse-recovery-boot": "http-stall-v1"],
            peer: "192.168.1.20")
        waiting = try json(engine.response(method: "GET", path: "/", headers: [:]).body)
        let readyPanel = try XCTUnwrap((waiting["interactions"] as? [String: Any])?["panel"] as? [String: Any])
        XCTAssertEqual(readyPanel["status"] as? String, "ready")
        XCTAssertEqual(readyPanel["route"] as? String, "/api/agent-status")
        XCTAssertEqual(readyPanel["httpStallRecoveryBoot"] as? Bool, true)
        XCTAssertFalse(try text(engine.response(method: "GET", path: "/", headers: [:]).body).contains("192.168.1.20"))
    }

    func testBindPrecedesProbesAndStopFollowsTheSpecOrder() throws {
        let transport = CountingTransport()
        var env = EngineEnvironment()
        env.automaticWorkers = false
        env.quotaTransport = transport
        env.claudeCandidates = { [ClaudeOAuthCandidate(token: "test-token")] }
        let recorder = RecordingRegistrar()
        env.discoveryRegistrar = recorder
        env.discoveryAddresses = { ["192.168.1.50"] }
        env.hostname = { "Test Host" }
        let engine = VibePulseEngine(port: 0, environment: env)
        engine.tick(.claudeProbe)
        XCTAssertEqual(transport.calls, 0)
        XCTAssertEqual(recorder.registered, 0)

        let occupied = try occupyHighPort()
        defer { close(occupied.fd) }
        XCTAssertNotEqual(occupied.port, 8737)
        let blocked = VibePulseEngine(port: occupied.port, environment: env)
        guard case let .portBusy(pid, command) = blocked.start() else {
            return XCTFail("expected the occupied port to be reported")
        }
        XCTAssertEqual(pid, ProcessInfo.processInfo.processIdentifier)
        XCTAssertNotNil(command)
        XCTAssertEqual(transport.calls, 0)
        XCTAssertEqual(recorder.registered, 0)
        XCTAssertTrue(blocked.stopTrace.isEmpty)

        guard case let .started(port) = engine.start() else {
            return XCTFail("ephemeral bind failed")
        }
        XCTAssertNotEqual(port, 8737)
        XCTAssertEqual(transport.calls, 0)
        XCTAssertEqual(recorder.registered, 1)
        let deadline = Date().addingTimeInterval(2)
        while engine.runningWorkersNow().count < EngineWorker.allCases.count && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(engine.runningWorkersNow(), Set(EngineWorker.allCases))
        for worker in EngineWorker.allCases {
            engine.tick(worker)
        }
        for worker in EngineWorker.allCases {
            XCTAssertEqual(engine.workerRuns[worker], 1, worker.rawValue)
        }
        XCTAssertEqual(transport.calls, 1)
        XCTAssertEqual(transport.urls.first, ClaudeLimits.usageURL)
        engine.handleSignal(SIGINT)
        XCTAssertEqual(engine.stopTrace, stopOrder)
        XCTAssertEqual(recorder.stopped, 1)
    }

    func testAWorkerErrorDoesNotStopTheOthers() throws {
        struct Boom: Error {}
        var env = EngineEnvironment()
        env.automaticWorkers = false
        env.transcriptOverride = { throw Boom() }
        let engine = VibePulseEngine(port: 0, environment: env)
        guard case .started = engine.start() else { return XCTFail("bind failed") }
        defer { engine.stop() }
        engine.tick(.transcript)
        engine.tick(.github)
        XCTAssertTrue(engine.workerErrors[.transcript]?.contains("Boom") == true)
        XCTAssertEqual(engine.workerRuns[.github], 1)
        XCTAssertNil(engine.workerErrors[.github])
        let body = try text(engine.response(
            method: "GET", path: "/api/tokens",
            headers: ["x-vibepulse-accepts": "usage-totals"]).body)
        XCTAssertTrue(body.contains("\"state\":\"failing\""))
        XCTAssertTrue(body.contains("\"placeholder\":true"))
    }

    func testListenerSetsContentLengthAndRejectsOverCap() throws {
        var env = EngineEnvironment()
        env.automaticWorkers = false
        let engine = VibePulseEngine(port: 0, environment: env)
        guard case let .started(port) = engine.start() else { return XCTFail("bind failed") }
        defer { engine.stop() }
        XCTAssertNotEqual(port, 8737)
        let github = exchange(port: port, request: "GET /api/github HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n")
        XCTAssertTrue(github.contains("HTTP/1.0 200 OK\r\n"))
        XCTAssertTrue(github.contains("Content-Length: "))
        XCTAssertTrue(github.contains("{\"v\":1,\"enabled\":false}"))
        let length = try contentLength(github)
        let body = github.split(separator: "\r\n\r\n", maxSplits: 1, omittingEmptySubsequences: false).last.map(String.init) ?? ""
        XCTAssertEqual(length, body.utf8.count)
        XCTAssertLessThan(length, VibePulseEngine.githubBodyCap)

        let payload = "{\"ignored\":true}"
        let rejected = exchange(
            port: port,
            request: "POST /api/hook/question HTTP/1.0\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(payload.utf8.count)\r\n\r\n\(payload)")
        XCTAssertTrue(rejected.contains("HTTP/1.0 404 Not Found\r\n"))
        XCTAssertTrue(rejected.contains("interactions are not enabled"))
        XCTAssertEqual(engine.jsonBodyReads, 0)

        var holders: [Int32] = []
        for _ in 0..<VibePulseEngine.defaultConnectionCap {
            holders.append(connectOnly(port))
        }
        Thread.sleep(forTimeInterval: 0.4)
        let busy = exchange(port: port, request: "GET /api/github HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\n\r\nbody")
        XCTAssertTrue(busy.contains("HTTP/1.1 503 Service Unavailable\r\n"), busy)
        XCTAssertTrue(busy.contains("Content-Length: 0\r\n"))
        XCTAssertTrue(busy.contains("Connection: close\r\n"))
        for fd in holders { close(fd) }
    }

    func testRealSIGINTStopsGracefully() throws {
        var env = EngineEnvironment()
        env.automaticWorkers = false
        env.trapSignals = true
        let engine = VibePulseEngine(port: 0, environment: env)
        guard case .started = engine.start() else { return XCTFail("bind failed") }
        kill(getpid(), SIGINT)
        let deadline = Date().addingTimeInterval(2)
        while engine.stopTrace.isEmpty && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(engine.stopTrace, stopOrder)
    }

    func testCodexQuestionAndPermissionUseTheLeafNormalizers() throws {
        var env = EngineEnvironment()
        env.codexInteractions = true
        env.interactionDetail = true
        env.interactionTimeout = 2
        let engine = VibePulseEngine(port: 0, environment: env)
        let thin = Data("{\"cwd\":\"/work/demo\",\"session_id\":\"s\",\"turn_id\":\"t\",\"question\":\"Which?\",\"options\":[{\"label\":\"Only\"}]}".utf8)
        let rejected = post(engine, "/api/codex/question", thin)
        XCTAssertEqual(rejected.status, 200)
        XCTAssertEqual(try text(rejected.body), "{\"status\":\"computer\",\"reason\":\"invalid\"}")
        XCTAssertNil(engine.interactionStore?.pendingPublic())

        let question = Data("""
        {"cwd":"/Users/niclas/vibepulse","session_id":"session-123","turn_id":"turn-456","question":"Which auth approach?","header":"Auth","options":[{"label":"Keep existing auth","description":"Smaller change"},{"label":"New auth layer","description":"Cleaner architecture","recommended":true}]}
        """.utf8)
        let parked = sendLater(engine, "/api/codex/question", question)
        let requestID = try waitForRequest(engine)
        let pending = try text(engine.response(method: "GET", path: "/api/agent-status", headers: [:]).body)
        XCTAssertTrue(pending.contains("\"provider\":\"codex\""))
        XCTAssertTrue(pending.contains("\"prompt\":\"Which auth approach?\""))
        XCTAssertTrue(pending.contains("\"can_approve\":true"))
        let answer = Data("{\"verdict\":\"approve\"}".utf8)
        let approved = post(engine, "/api/interaction/\(requestID)", answer, peer: "192.168.1.40")
        XCTAssertEqual(approved.status, 200)
        wait(for: [parked.done], timeout: 3)
        let hook = try XCTUnwrap(parked.box.response)
        XCTAssertEqual(try text(hook.body), "{\"status\":\"answered\",\"option_index\":1,\"answer\":\"New auth layer\"}")

        var quiet = EngineEnvironment()
        quiet.codexInteractions = true
        quiet.interactionDetail = false
        quiet.interactionTimeout = 2
        let hidden = VibePulseEngine(port: 0, environment: quiet)
        let hiddenPark = sendLater(hidden, "/api/codex/question", question)
        _ = try waitForRequest(hidden)
        let redacted = try text(hidden.response(method: "GET", path: "/api/agent-status", headers: [:]).body)
        XCTAssertFalse(redacted.contains("Which auth approach?"))
        XCTAssertFalse(redacted.contains("New auth layer"))
        XCTAssertTrue(redacted.contains("\"can_approve\":false"))
        XCTAssertTrue(redacted.contains("\"provider\":\"codex\""))
        let hiddenID = try XCTUnwrap(hidden.interactionStore?.pendingPublic()?.string("request_id"))
        _ = post(hidden, "/api/interaction/\(hiddenID)", Data("{\"verdict\":\"deny\"}".utf8), peer: "192.168.1.40")
        wait(for: [hiddenPark.done], timeout: 3)
        XCTAssertEqual(try text(XCTUnwrap(hiddenPark.box.response).body), "{\"status\":\"computer\",\"reason\":\"deny\"}")

        let permission = Data("""
        {"hook_event_name":"PermissionRequest","session_id":"session-123","turn_id":"turn-456","cwd":"/Users/niclas/vibepulse","tool_name":"Bash","tool_input":{"command":"git status"}}
        """.utf8)
        let permissionPark = sendLater(engine, "/api/codex/permission", permission)
        let permissionID = try waitForRequest(engine)
        XCTAssertEqual(engine.interactionStore?.pendingPublic()?.bool("can_approve"), true)
        _ = post(engine, "/api/interaction/\(permissionID)", Data("{\"verdict\":\"deny\"}".utf8), peer: "192.168.1.40")
        wait(for: [permissionPark.done], timeout: 3)
        let decision = try text(XCTUnwrap(permissionPark.box.response).body)
        XCTAssertEqual(decision, "{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"deny\",\"message\":\"Denied from VibePulse\"}}}")

        let invalidPermission = Data("{\"hook_event_name\":\"PreToolUse\"}".utf8)
        let noDecision = post(engine, "/api/codex/permission", invalidPermission)
        XCTAssertEqual(noDecision.status, 200)
        XCTAssertEqual(noDecision.body, Data())
        XCTAssertNil(engine.interactionStore?.pendingPublic())
    }

    func testLegacyClaudeParkLegacyLeavesCodexOnPark() throws {
        let clock = FixedClock(wall: 50_000, monotonic: 1_000)
        let secret = "legacy-secret"
        var env = EngineEnvironment()
        env.clock = clock
        env.claudeInteractions = true
        env.codexInteractions = true
        env.legacyClaudePanelV1 = true
        env.interactionDetail = true
        env.interactionTimeout = 2
        env.interactionSecret = secret
        let engine = VibePulseEngine(port: 0, environment: env)

        let codexBody = Data("{\"cwd\":\"/work/demo\",\"session_id\":\"s\",\"turn_id\":\"t\",\"question\":\"Which?\",\"options\":[{\"label\":\"A\"},{\"label\":\"B\"}]}".utf8)
        let codexPark = sendLater(engine, "/api/codex/question", codexBody)
        let codexID = try waitForRequest(engine)
        let codexPending = try XCTUnwrap(engine.interactionStore?.pendingPublic())
        XCTAssertEqual(codexPending.string("provider"), "codex")
        XCTAssertEqual(codexPending.string("view_sha256")?.count, 64)
        let codexDigest = try XCTUnwrap(codexPending.string("view_sha256"))
        let codexMac = signAnswerV2(
            secret: secret, provider: "codex", requestID: codexID, digest: codexDigest,
            verdict: "deny", timestamp: 50_000)
        let codexAnswer = post(
            engine, "/api/interaction/\(codexID)",
            Data("{\"verdict\":\"deny\",\"ts\":50000,\"hmac\":\"\(codexMac)\"}".utf8),
            peer: "192.168.1.40")
        XCTAssertEqual(codexAnswer.status, 200)
        wait(for: [codexPark.done], timeout: 3)
        XCTAssertEqual(try text(XCTUnwrap(codexPark.box.response).body), "{\"status\":\"computer\",\"reason\":\"deny\"}")

        let event = Data("""
        {"cwd":"/work/bright-octopus","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which one?","options":[{"label":"Option A (recommended)","description":"desc"},{"label":"Option B"}]}]}}
        """.utf8)
        let claudePark = sendLater(engine, "/api/hook/question", event)
        let requestID = try waitForRequest(engine)
        let status = try text(engine.response(method: "GET", path: "/api/agent-status", headers: [:]).body)
        XCTAssertTrue(status.hasPrefix("{\"v\":2,\"seq\":"))
        XCTAssertTrue(status.contains("\"agents\":"))
        XCTAssertFalse(status.contains("\"provider\""))
        XCTAssertFalse(status.contains("view_sha256"))
        XCTAssertEqual(engine.interactionStore?.pendingPublic()?.string("kind"), "question")
        let job = try XCTUnwrap(engine.interactionStore?.relayJob(for: requestID))
        let digest = CryptoKit.SHA256.hash(data: job.canonicalViewBytes).map { String(format: "%02x", $0) }.joined()
        let v2 = signAnswerV2(
            secret: secret, provider: "claude", requestID: requestID, digest: digest,
            verdict: "deny", timestamp: 50_000)
        let rejected = post(
            engine, "/api/interaction/\(requestID)",
            Data("{\"verdict\":\"deny\",\"ts\":50000,\"hmac\":\"\(v2)\"}".utf8),
            peer: "192.168.1.40")
        XCTAssertEqual(rejected.status, 409)
        XCTAssertEqual(engine.interactionStore?.pendingPublic()?.string("request_id"), requestID)
        let v1 = signAnswerV1(secret: secret, requestID: requestID, verdict: "deny", timestamp: 50_000)
        let accepted = post(
            engine, "/api/interaction/\(requestID)",
            Data("{\"verdict\":\"deny\",\"ts\":50000,\"hmac\":\"\(v1)\"}".utf8),
            peer: "192.168.1.40")
        XCTAssertEqual(accepted.status, 200)
        wait(for: [claudePark.done], timeout: 3)
        XCTAssertTrue(try text(XCTUnwrap(claudePark.box.response).body).contains("\"permissionDecision\":\"deny\""))
        XCTAssertNil(engine.interactionStore?.pendingPublic())
    }

    func testPanicDeniesParkedItemsAfterTheJSONGate() throws {
        var env = EngineEnvironment()
        env.claudeInteractions = true
        env.interactionTimeout = 2
        let engine = VibePulseEngine(port: 0, environment: env)
        let garbage = Data("nope".utf8)
        let bad = post(engine, "/api/panic", garbage, peer: "192.168.1.9")
        XCTAssertEqual(bad.status, 400)
        XCTAssertEqual(try text(bad.body), "{\"ok\":false,\"reason\":\"bad request\"}")

        let event = Data("""
        {"cwd":"/work/bright-octopus","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which one?","options":[{"label":"Option A (recommended)","description":"desc"},{"label":"Option B"}]}]}}
        """.utf8)
        let parked = sendLater(engine, "/api/hook/question", event)
        _ = try waitForRequest(engine)
        let panicBody = Data("{\"ts\":1}".utf8)
        let panic = post(engine, "/api/panic", panicBody, peer: "192.168.1.9")
        XCTAssertEqual(panic.status, 200)
        XCTAssertEqual(try text(panic.body), "{\"ok\":true,\"denied\":1}")
        wait(for: [parked.done], timeout: 3)
        XCTAssertTrue(try text(XCTUnwrap(parked.box.response).body).contains("\"permissionDecision\":\"deny\""))
        XCTAssertNil(engine.interactionStore?.pendingPublic())
        let again = post(engine, "/api/panic", panicBody, peer: "192.168.1.9")
        XCTAssertEqual(try text(again.body), "{\"ok\":true,\"denied\":0}")
    }

    func testRelayHandoffReadsTheStoreJobAndSignsThroughAnswer() throws {
        let token = InteractionRelayCrypto.b64URLEncode(Data(repeating: 0x22, count: 32))
        let calls = RelayCapture()
        var env = EngineEnvironment()
        env.clock = FixedClock(wall: 50_000, monotonic: 1_000)
        env.claudeInteractions = true
        env.interactionTimeout = 2
        env.interactionSecret = String(repeating: "c", count: 32)
        env.relay = EngineRelayConfig(
            baseURL: "https://relay.example/",
            mailbox: "vp_A1b2C3d4E5f6G7h8",
            macToken: token,
            deviceKeyHex: String(repeating: "ab", count: 32),
            transport: { try calls.send($0) }
        )
        let engine = VibePulseEngine(port: 0, environment: env)
        let event = Data("""
        {"cwd":"/work/bright-octopus","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which one?","options":[{"label":"Option A (recommended)","description":"desc"},{"label":"Option B"}]}]}}
        """.utf8)
        let parked = sendLater(engine, "/api/hook/question", event)
        let requestID = try waitForRequest(engine)
        let stored = try XCTUnwrap(engine.interactionStore?.relayJob(for: requestID))
        let relay = try XCTUnwrap(engine.bridge?.relay)
        XCTAssertGreaterThanOrEqual(relay.publishQueueSize, 1)
        let resolution = RelayResolution(
            requestID: requestID, challenge: stored.challenge,
            viewSHA256: Data(CryptoKit.SHA256.hash(data: stored.canonicalViewBytes)),
            verdict: "deny", mac: Data(repeating: 1, count: 32))
        var sawStoreJob = false
        let rejected = engine.bridge?.resolve(resolution) { job, _ in
            sawStoreJob = job.requestID == stored.requestID
                && job.challenge == stored.challenge
                && job.viewBytes == stored.canonicalViewBytes
                && job.provider == "claude"
                && job.canApprove == stored.canApprove
            return false
        }
        XCTAssertEqual(rejected?.accepted, false)
        XCTAssertTrue(sawStoreJob)
        XCTAssertEqual(engine.interactionStore?.pendingPublic()?.string("request_id"), requestID)
        let accepted = engine.bridge?.resolve(resolution) { _, _ in true }
        XCTAssertEqual(accepted?.accepted, true)
        XCTAssertEqual(accepted?.reason, "ok")
        wait(for: [parked.done], timeout: 3)
        XCTAssertTrue(try text(XCTUnwrap(parked.box.response).body).contains("\"permissionDecision\":\"deny\""))
        XCTAssertNil(engine.interactionStore?.pendingPublic())
        XCTAssertGreaterThanOrEqual(relay.publishQueueSize, 2)
    }

    func testQuotaRegressionsUseTheHistoryFeed() throws {
        let clock = FixedClock(wall: 9_000, monotonic: 100)
        var env = EngineEnvironment()
        env.clock = clock
        let engine = VibePulseEngine(port: 0, environment: env)
        let before = try text(engine.response(method: "GET", path: "/", headers: [:]).body)
        XCTAssertTrue(before.contains("\"quotaRegressions\":[]"))
        XCTAssertTrue(engine.history.record(provider: "claude", window: "week", pct: 60, resetAt: 30_000, at: 1_000))
        XCTAssertTrue(engine.history.record(provider: "claude", window: "week", pct: 40, resetAt: 30_000, at: 2_000))
        let after = try text(engine.response(method: "GET", path: "/", headers: [:]).body)
        XCTAssertTrue(after.contains(
            "\"quotaRegressions\":[{\"provider\":\"claude\",\"scope\":\"general_weekly\",\"livePct\":40,\"cachedPct\":60,\"resetAt\":30000,\"at\":2000}]"
        ))
    }

    func testCodexProbeViewAndPublishRules() throws {
        let clock = StepClock(wall: 1_700_000_000, monotonic: 1_000)
        let apps = CodexAppBox()
        var quota = CodexQuota()
        quota.codexWeekPct = 12
        quota.codexWeekResetAt = 1_800_000_000
        quota.codexWeekWindowMinutes = 10_080
        apps.quota = quota
        var env = EngineEnvironment()
        env.clock = clock
        env.automaticWorkers = false
        env.codexAppServer = { try apps.fetch($0) }
        let engine = VibePulseEngine(port: 0, environment: env)
        guard case let .started(port) = engine.start() else { return XCTFail("bind failed") }
        defer { engine.stop() }
        XCTAssertNotEqual(port, 8737)
        let idle = try text(engine.response(method: "GET", path: "/", headers: [:]).body)
        XCTAssertTrue(idle.contains("\"codexProbe\":\"not_run\""))
        XCTAssertTrue(idle.contains("\"codexProbeStreak\":0"))
        XCTAssertTrue(idle.contains("\"codexProbeIntervalS\":240"))
        XCTAssertTrue(idle.contains("\"codexProbeCooldownLeftS\":null"))
        XCTAssertTrue(idle.contains("\"codexProbeAgeS\":null"))
        XCTAssertEqual(apps.calls, 0)

        engine.tick(.codexProbe)
        XCTAssertEqual(apps.calls, 1)
        let published = try text(engine.response(
            method: "GET", path: "/api/tokens",
            headers: ["x-vibepulse-accepts": "usage-totals"]).body)
        XCTAssertTrue(published.contains("\"codexWeekPct\":12"))
        clock.monotonicTime = 1_017
        let aged = try text(engine.response(method: "GET", path: "/", headers: [:]).body)
        XCTAssertTrue(aged.contains("\"codexProbe\":\"cli\""))
        XCTAssertTrue(aged.contains("\"codexProbeStreak\":0"))
        XCTAssertTrue(aged.contains("\"codexProbeIntervalS\":15"))
        XCTAssertTrue(aged.contains("\"codexProbeCooldownLeftS\":null"))
        XCTAssertTrue(aged.contains("\"codexProbeAgeS\":17"))
        XCTAssertEqual(apps.calls, 1)

        let transport = CountingTransport()
        var heldEnv = EngineEnvironment()
        heldEnv.clock = FixedClock(wall: 1_700_000_000, monotonic: 1_000)
        heldEnv.automaticWorkers = false
        heldEnv.quotaTransport = transport
        let auth = heldEnv.stateDirectory.appendingPathComponent("codex-auth.json")
        let token = jwt(#"{"exp":1900000000,"sub":"acct"}"#)
        try #"{"tokens":{"access_token":"\#(token)","account_id":"acct"}}"#.write(to: auth, atomically: true, encoding: .utf8)
        heldEnv.codexAuthPath = auth
        let held = VibePulseEngine(port: 0, environment: heldEnv)
        guard case let .started(heldPort) = held.start() else { return XCTFail("bind failed") }
        defer { held.stop() }
        XCTAssertNotEqual(heldPort, 8737)
        let lock = ProbeFileLock.acquire(heldEnv.stateDirectory.appendingPathComponent(CodexProbe.lockFileName))
        XCTAssertNotNil(lock)
        defer { lock?.release() }
        var preset = CodexQuota()
        preset.codexWeekPct = 77
        preset.codexWeekResetAt = 1_800_000_000
        preset.codexWeekWindowMinutes = 10_080
        held.codexQuota = preset
        held.tick(.codexProbe)
        XCTAssertEqual(transport.calls, 0)
        let kept = try text(held.response(
            method: "GET", path: "/api/tokens",
            headers: ["x-vibepulse-accepts": "usage-totals"]).body)
        XCTAssertTrue(kept.contains("\"codexWeekPct\":77"))
        let heldDiag = try text(held.response(method: "GET", path: "/", headers: [:]).body)
        XCTAssertTrue(heldDiag.contains("\"codexProbe\":\"probe_held_by_other_instance\""))
        XCTAssertTrue(heldDiag.contains("\"codexProbeAgeS\":0"))
        XCTAssertTrue(heldDiag.contains("\"codexProbeCooldownLeftS\":null"))
    }

    func testCodexProbeCadenceFollowsTheProbeInterval() throws {
        let clock = StepClock(wall: 1_700_000_000, monotonic: 1_000)
        var env = EngineEnvironment()
        env.clock = clock
        env.automaticWorkers = true
        let engine = VibePulseEngine(port: 0, environment: env)
        guard case let .started(port) = engine.start() else { return XCTFail("bind failed") }
        defer { engine.stop() }
        XCTAssertNotEqual(port, 8737)
        XCTAssertTrue(waitUntil(2) { engine.workerRunCount(.codexProbe) == 1 })
        let afterFirst = try text(engine.response(method: "GET", path: "/", headers: [:]).body)
        XCTAssertTrue(afterFirst.contains("\"codexProbeIntervalS\":15"))
        clock.monotonicTime = 1_010
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(engine.workerRunCount(.codexProbe), 1)
        clock.monotonicTime = 1_030
        XCTAssertTrue(waitUntil(2) { engine.workerRunCount(.codexProbe) == 2 })
    }

    func testAgentStatusStopJoinsThePollLoop() throws {
        var env = EngineEnvironment()
        env.automaticWorkers = true
        let project = env.projectsDirectory.appendingPathComponent("demo", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let line = "{\"type\":\"user\",\"sessionId\":\"session-1\",\"uuid\":\"event-1\",\"cwd\":\"/Users/test/Torget\"}\n"
        try line.write(to: project.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        let engine = VibePulseEngine(port: 0, environment: env)
        guard case let .started(port) = engine.start() else { return XCTFail("bind failed") }
        defer { engine.stop() }
        XCTAssertNotEqual(port, 8737)
        var seen = ""
        let polled = waitUntil(3) {
            seen = (try? self.text(engine.response(method: "GET", path: "/api/agent-status", headers: [:]).body)) ?? ""
            return seen.hasPrefix("{\"v\":2,\"seq\":") && seen.contains("\"seq\":1") && seen.contains("\"agents\":")
        }
        XCTAssertTrue(polled, seen)
        engine.stop()
        let started = Date()
        engine.agentStatus.pollOnceLoop(interval: 30)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertEqual(engine.stopTrace, stopOrder)
        engine.stop()
        XCTAssertEqual(engine.stopTrace, stopOrder)
        XCTAssertGreaterThanOrEqual(engine.agentStatus.pollOnce(), 0)
    }

    private func text(_ data: Data) throws -> String {
        try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func waitForRequest(_ engine: VibePulseEngine) throws -> String {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let id = engine.interactionStore?.pendingPublic()?.string("request_id") {
                return id
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("hook did not park")
        return ""
    }

    private func jsonHeaders(_ body: Data, host: String = "localhost") -> [String: String] {
        [
            "content-type": "application/json",
            "content-length": "\(body.count)",
            "host": host,
        ]
    }

    private func post(_ engine: VibePulseEngine, _ path: String, _ body: Data, peer: String = "127.0.0.1") -> HTTPResponse {
        engine.response(method: "POST", path: path, headers: jsonHeaders(body), body: body, peer: peer)
    }

    private func sendLater(_ engine: VibePulseEngine, _ path: String, _ body: Data, peer: String = "127.0.0.1") -> (box: ResponseBox, done: XCTestExpectation) {
        let done = expectation(description: path)
        let box = ResponseBox()
        let headers = jsonHeaders(body)
        DispatchQueue.global().async {
            box.response = engine.response(
                method: "POST", path: path, headers: headers, body: body, peer: peer)
            done.fulfill()
        }
        return (box, done)
    }

    private func waitUntil(_ timeout: TimeInterval, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return predicate()
    }

    private func signAnswerV1(secret: String, requestID: String, verdict: String, timestamp: Int) -> String {
        let message = Data("\(requestID)|\(verdict)|\(timestamp)".utf8)
        let code = HMAC<CryptoKit.SHA256>.authenticationCode(for: message, using: SymmetricKey(data: Data(secret.utf8)))
        return code.map { String(format: "%02x", $0) }.joined()
    }

    private func jwt(_ payload: String) -> String {
        let encoded = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(encoded).sig"
    }

    private func contentLength(_ response: String) throws -> Int {
        for line in response.split(separator: "\r\n") {
            let text = String(line)
            if text.lowercased().hasPrefix("content-length:") {
                return try XCTUnwrap(Int(text.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? ""))
            }
        }
        XCTFail("missing content length")
        return -1
    }
}

private final class CountingTransport: QuotaHTTPTransport, @unchecked Sendable {
    var calls = 0
    var urls: [String] = []
    func send(_ request: QuotaHTTPRequest) throws -> QuotaHTTPResponse {
        calls += 1
        urls.append(request.url)
        return QuotaHTTPResponse(status: 401, body: Data())
    }
}

private final class StepClock: Clock, @unchecked Sendable {
    var wallTime: TimeInterval
    var monotonicTime: TimeInterval
    init(wall: TimeInterval, monotonic: TimeInterval) {
        wallTime = wall
        monotonicTime = monotonic
    }
    func wall() -> TimeInterval { wallTime }
    func monotonic() -> TimeInterval { monotonicTime }
}

private final class CodexAppBox: @unchecked Sendable {
    var calls = 0
    var quota = CodexQuota()
    func fetch(_ now: TimeInterval) throws -> CodexQuota {
        calls += 1
        return quota
    }
}

private final class RelayCapture: @unchecked Sendable {
    func send(_ request: RelayHTTPRequest) throws -> RelayHTTPResponse {
        RelayHTTPResponse(status: 204, headers: [("Cache-Control", "no-store")], body: Data())
    }
}

private final class ResponseBox: @unchecked Sendable {
    var response: HTTPResponse?
}

private final class RecordingRegistrar: DiscoveryRegistering, @unchecked Sendable {
    var registered = 0
    var stopped = 0
    func register(_ advertisement: DiscoveryAdvertisement) throws { registered += 1 }
    func unregister() { stopped += 1 }
}

private func occupyHighPort() throws -> (fd: Int32, port: Int) {
    for _ in 0..<8 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { continue }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = in_addr_t(0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0 || listen(fd, 1) != 0 {
            close(fd)
            continue
        }
        var stored = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &stored) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        let port = Int(UInt16(bigEndian: stored.sin_port))
        if named == 0, port != 8737, port != 0 {
            return (fd, port)
        }
        close(fd)
    }
    throw POSIXError(.EADDRNOTAVAIL)
}

private func connectOnly(_ port: Int) -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    _ = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return fd
}

private func exchange(port: Int, request: String) -> String {
    let fd = connectOnly(port)
    defer { close(fd) }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    _ = request.withCString { send(fd, $0, strlen($0), 0) }
    var buffer = [UInt8](repeating: 0, count: 8192)
    var collected = Data()
    while collected.count < 8192 {
        let count = recv(fd, &buffer, buffer.count, 0)
        if count <= 0 { break }
        collected.append(buffer, count: count)
        if collected.range(of: Data("\r\n\r\n".utf8)) != nil,
           let text = String(data: collected, encoding: .utf8),
           let length = headerLength(text),
           let headerEnd = text.range(of: "\r\n\r\n") {
            let headerBytes = Data(text[..<headerEnd.upperBound].utf8).count
            if collected.count >= headerBytes + length { break }
        }
    }
    return String(data: collected, encoding: .utf8) ?? ""
}

private func headerLength(_ response: String) -> Int? {
    for line in response.split(separator: "\r\n") {
        let text = String(line)
        if text.lowercased().hasPrefix("content-length:") {
            return Int(text.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "")
        }
    }
    return nil
}
