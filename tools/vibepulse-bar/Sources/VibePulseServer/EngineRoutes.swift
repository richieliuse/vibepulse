import Foundation
import VibePulseAgents
import VibePulseProviders
import VibePulseRelay
import VibePulseState

private let hookJSONLimit = 64 * 1024
private let answerJSONLimit = 4096
private let contentTypePattern = try! NSRegularExpression(
    pattern: #"^application/json(?:\s*;\s*charset\s*=\s*(?:utf-8|"utf-8"))?$"#,
    options: [.caseInsensitive]
)

extension VibePulseEngine {
    func handle(_ request: HTTPRequest) -> HTTPResponse {
        let method = request.method.uppercased()
        if method == "GET" {
            return handleGET(request)
        }
        if method == "POST" {
            return handlePOST(request)
        }
        let body = Data("<html><body>Unsupported method ('\(method)')</body></html>".utf8)
        return HTTPResponse(status: 501, body: body, contentType: "text/html;charset=utf-8")
    }

    private func handleGET(_ request: HTTPRequest) -> HTTPResponse {
        let path = request.path
        if path == "/api/tokens" || path == "/api/agent-status" || path == "/api/max-tracker" || path == "/api/github" {
            recordPanel(peer: request.peer, path: path, recovery: request.headerValues("x-vibepulse-recovery-boot"))
        }
        switch path {
        case "/api/tokens":
            let snap = currentTokens()
            if usageTotalsArePlaceholders(snap), !acceptsUsageTotals(request) {
                let totals = snap.object?["usageTotals"] ?? .object([("placeholder", .bool(true))])
                return .json(503, .object([
                    ("error", .string("usage totals not measured yet")),
                    ("usageTotals", totals),
                ]))
            }
            publishPeaks(from: snap)
            return .json(200, snap)
        case "/api/agent-status":
            return .json(200, agentPayload())
        case "/api/max-tracker":
            let snap = currentTokens()
            publishPeaks(from: snap)
            return .json(200, maxTrackerPayload(quota: snap))
        case "/api/github":
            return .json(200, githubPayload())
        case "/":
            return .json(200, diagnosticsPayload())
        default:
            return .json(404, .object([("error", .string("not found"))]))
        }
    }

    private func handlePOST(_ request: HTTPRequest) -> HTTPResponse {
        let path = request.path
        let claudeRoute = path == "/api/hook/question" || path == "/api/hook/permission"
        let codexRoute = path == "/api/codex/question" || path == "/api/codex/permission"
        let answerRoute = path.hasPrefix("/api/interaction/")
        let panicRoute = path == "/api/panic"
        let store = interactionStore

        if claudeRoute && (store == nil || !environment.claudeInteractions) {
            return interactionsDisabled()
        }
        if codexRoute && (store == nil || !environment.codexInteractions) {
            return interactionsDisabled()
        }
        if claudeRoute || codexRoute {
            if !isLoopbackPeer(request.peer) {
                return .json(403, .object([("error", .string("hooks must be local"))]))
            }
            if !hasValidLoopbackHost(request) || !request.headerValues("origin").isEmpty {
                return .json(403, .object([("error", .string("hook ingress rejected"))]))
            }
        }
        if (answerRoute || panicRoute) && store == nil {
            return interactionsDisabled()
        }
        if (claudeRoute || codexRoute || answerRoute || panicRoute) && !hasJSONContentType(request) {
            return .json(415, .object([("error", .string("application/json required"))]))
        }
        if claudeRoute {
            let kind = path.hasSuffix("question") ? "question" : "approval"
            return handleClaudeHook(kind: kind, request: request)
        }
        if path == "/api/codex/question" {
            return handleCodexQuestion(request)
        }
        if path == "/api/codex/permission" {
            return handleCodexPermission(request)
        }
        if store == nil {
            return interactionsDisabled()
        }
        if answerRoute {
            let requestID = String(path.dropFirst("/api/interaction/".count))
            return handleAnswer(requestID: requestID, request: request)
        }
        if panicRoute {
            return handlePanic(request)
        }
        return .json(404, .object([("error", .string("not found"))]))
    }

    private func handleClaudeHook(kind: String, request: HTTPRequest) -> HTTPResponse {
        guard let event = parseObject(request, limit: hookJSONLimit),
              let raw = String(data: request.body, encoding: .utf8),
              let store = interactionStore
        else { return .emptyOK() }
        let timeout = environment.interactionTimeout
        let requestID: String?
        if environment.legacyClaudePanelV1 {
            requestID = store.parkLegacy(kind: kind, eventJSON: raw, holdSeconds: timeout)
        } else {
            requestID = store.park(kind: kind, eventJSON: raw, holdSeconds: timeout)
        }
        guard let requestID else { return .emptyOK() }
        guard let result = store.awaitVerdict(requestID: requestID, timeout: timeout) else { return .emptyOK() }
        guard let body = claudeHookBody(kind: kind, verdict: result.verdict, optionIndex: result.optionIndex, event: event) else {
            return .emptyOK()
        }
        return .json(200, body)
    }

    private func handleCodexQuestion(_ request: HTTPRequest) -> HTTPResponse {
        guard let event = parseObject(request, limit: hookJSONLimit) else { return computer("invalid") }
        let allowed: Set<String> = ["cwd", "session_id", "turn_id", "question", "header", "options"]
        let identity: Set<String> = ["cwd", "session_id", "turn_id"]
        guard Set(event.keys).isSubset(of: allowed),
              identity.isSubset(of: Set(event.keys)),
              let question = event["question"],
              let options = event["options"],
              let cwd = event["cwd"] as? String,
              let sessionID = event["session_id"] as? String,
              let turnID = event["turn_id"] as? String,
              let store = interactionStore
        else { return computer("invalid") }
        var payload: [String: Any] = ["question": question, "options": options]
        if let header = event["header"] { payload["header"] = header }
        guard var normalized = normalizeCodexQuestion(
            payload: payload, cwd: cwd, sessionID: sessionID, turnID: turnID
        ) else { return computer("invalid") }
        if !environment.interactionDetail {
            normalized = strippedCodexQuestion(normalized)
        }
        let timeout = environment.interactionTimeout
        guard let requestID = store.park(normalized, holdSeconds: timeout) else {
            return computer("unavailable")
        }
        guard let result = store.awaitVerdict(requestID: requestID, timeout: timeout) else {
            return computer(request.isAlive() ? "timeout" : "disconnected")
        }
        return .json(200, codexQuestionBody(verdict: result.verdict, normalized: normalized))
    }

    private func handleCodexPermission(_ request: HTTPRequest) -> HTTPResponse {
        guard let event = parseObject(request, limit: hookJSONLimit),
              let store = interactionStore,
              let normalized = normalizeCodexPermission(event: event, reveal: environment.interactionDetail)
        else { return .emptyOK() }
        let timeout = environment.interactionTimeout
        guard let requestID = store.park(normalized, holdSeconds: timeout) else { return .emptyOK() }
        guard let result = store.awaitVerdict(requestID: requestID, timeout: timeout),
              let body = codexPermissionBody(result.verdict)
        else { return .emptyOK() }
        return .json(200, body)
    }

    private func computer(_ reason: String) -> HTTPResponse {
        .json(200, .object([("status", .string("computer")), ("reason", .string(reason))]))
    }

    private func handleAnswer(requestID: String, request: HTTPRequest) -> HTTPResponse {
        guard let payload = parseObject(request, limit: answerJSONLimit) else {
            return .json(400, .object([("ok", .bool(false)), ("reason", .string("bad request"))]))
        }
        guard let verdict = payload["verdict"] as? String else {
            return .json(400, .object([("ok", .bool(false)), ("reason", .string("bad request"))]))
        }
        let mac = payload["hmac"] as? String
        let timestamp = jsonInt(payload["ts"])
        if bridge?.commit(requestID: requestID, verdict: verdict, mac: mac, timestamp: timestamp, reason: "resolved") != nil {
            return .json(200, .object([("ok", .bool(true)), ("reason", .string("ok"))]))
        }
        return .json(409, .object([("ok", .bool(false)), ("reason", .string("rejected"))]))
    }

    private func handlePanic(_ request: HTTPRequest) -> HTTPResponse {
        guard parseObject(request, limit: answerJSONLimit) != nil else {
            return .json(400, .object([("ok", .bool(false)), ("reason", .string("bad request"))]))
        }
        let denied = interactionStore?.panic() ?? 0
        return .json(200, .object([("ok", .bool(true)), ("denied", .int(denied))]))
    }

    private func parseObject(_ request: HTTPRequest, limit: Int) -> [String: Any]? {
        guard request.advertisedLength > 0, request.advertisedLength <= limit, request.bodyComplete else { return nil }
        noteJSONRead()
        guard request.body.count == request.advertisedLength else { return nil }
        return jsonObject(from: request.body)
    }

    private func interactionsDisabled() -> HTTPResponse {
        .json(404, .object([("error", .string("interactions are not enabled"))]))
    }

    func agentPayload(includePending: Bool = true) -> JSONValue {
        var payload = JSONValue.from(wire: agentStatus.snapshot())
        guard includePending, let pending = interactionStore?.pendingPublic() else { return payload }
        guard case var .object(pairs) = payload else { return payload }
        let candidatePairs = pairs + [("pending", JSONValue.from(wire: pending))]
        let candidate = JSONValue.object(candidatePairs)
        if let encoded = try? candidate.encode(), encoded.count <= Self.pendingBodyCeiling {
            pairs = candidatePairs
            payload = .object(pairs)
        }
        return payload
    }

    func maxTrackerPayload(quota: JSONValue? = nil) -> JSONValue {
        let source = quota ?? currentTokens()
        let today = localDay(environment.clock.wall())
        let shot = maxTracker.snapshot(today: today, plans: environment.plans)
        let fields = source.object
        let stale = fields?["claudeWeekStale"] == .bool(true) || fields?["codexWeekStale"] == .bool(true)
        return .object([
            ("v", .int(shot.v)),
            ("weeks", .int(shot.weeks)),
            ("stale", .bool(stale)),
            ("codingStreakDays", shot.codingStreakDays.map(JSONValue.int) ?? .null),
            ("claude", providerJSON(shot.claude)),
            ("codex", providerJSON(shot.codex)),
        ])
    }

    func githubPayload() -> JSONValue {
        guard let shot = githubMonitor?.snapshot() else {
            return .object([("v", .int(1)), ("enabled", .bool(false))])
        }
        var pairs: [(String, JSONValue)] = [
            ("v", .int(shot.version)),
            ("enabled", .bool(shot.enabled)),
        ]
        if let repo = shot.repo { pairs.append(("repo", .string(repo))) }
        if let project = shot.project { pairs.append(("project", .string(project))) }
        if let stale = shot.stale { pairs.append(("stale", .bool(stale))) }
        if let stars = shot.stars { pairs.append(("stars", .int(stars))) }
        if let forks = shot.forks { pairs.append(("forks", .int(forks))) }
        if let event = shot.event {
            pairs.append(("eventId", .string(event.eventID)))
            pairs.append(("actor", event.actor.map(JSONValue.string) ?? .null))
            pairs.append(("eventStars", .int(event.eventStars)))
        }
        return .object(pairs)
    }

    func diagnosticsPayload() -> JSONValue {
        let wall = environment.clock.wall()
        let mono = environment.clock.monotonic()
        let claudeDiag = claudeProbe
        let codexView = codexProbe.view(now: wall, monotonic: mono)
        let credential = claudeDiag.credential
        var credentialPairs: [(String, JSONValue)] = [("status", .string(credential.status))]
        if let minutes = credential.expiresInMin { credentialPairs.append(("expiresInMin", .int(minutes))) }
        if let reason = credential.reason { credentialPairs.append(("reason", .string(reason))) }
        let grok = grokProbe.diagnostics(monotonic: mono, wall: wall)
        let cursor = cursorProbe.diagnostics(monotonic: mono, wall: wall)
        let failingSince = computeFailingSince
        let saveFailing = maxTrackerSaveFailingSince
        var discoveryPairs: [(String, JSONValue)] = [("status", .string(discovery.status))]
        if let reason = discovery.reason { discoveryPairs.append(("reason", .string(reason))) }
        var relayPairs: [(String, JSONValue)] = [("status", .string(relayStatus))]
        if let relayReason { relayPairs.append(("reason", .string(relayReason))) }
        var agentRelayPairs: [(String, JSONValue)] = [("status", .string(agentRelayStatus))]
        if let agentRelayReason { agentRelayPairs.append(("reason", .string(agentRelayReason))) }
        let transport = (relayStatus == "ready" || agentRelayStatus == "ready") ? "lan+encrypted-relay" : "lan"
        let identity: [(String, JSONValue)] = [
            ("service", .string("torget-tokenserver")),
            ("rev", .string("unknown")),
            ("srcFingerprint", .string("unknown")),
            ("startedAt", .string(localISO8601(startedAt))),
            ("endpoint", .string("/api/tokens")),
            ("endpoints", .array([
                .string("/api/tokens"), .string("/api/agent-status"),
                .string("/api/max-tracker"), .string("/api/github"),
            ])),
            ("github", githubPayload()),
        ]
        let claudeProbeFields: [(String, JSONValue)] = [
            ("claudeProbe", .string(claudeDiag.status)),
            ("claudeProbeStreak", .int(claudeDiag.failureStreak)),
            ("claudeProbeIntervalS", .int(Int(claudeDiag.interval.rounded(.towardZero)))),
            ("claudeProbeCooldownLeftS", claudeDiag.cooldownLeft(at: wall).map(JSONValue.int) ?? .null),
            ("claudeProbeAgeS", claudeDiag.age(at: mono).map(JSONValue.int) ?? .null),
            ("claudeCredential", .object(credentialPairs)),
            ("ratelimitHeaders", .array(claudeDiag.ratelimitHeaders.map(JSONValue.string))),
            ("unknownRateLimitBuckets", .array(claudeDiag.unknownBuckets.map(JSONValue.string))),
        ]
        let otherProbes: [(String, JSONValue)] = [
            ("codexProbe", .string(codexView.status)),
            ("codexProbeStreak", .int(codexView.streak)),
            ("codexProbeIntervalS", .int(codexView.interval)),
            ("codexProbeCooldownLeftS", codexView.cooldownLeft.map(JSONValue.int) ?? .null),
            ("codexProbeAgeS", codexView.age.map(JSONValue.int) ?? .null),
            ("grokProbe", .string(grok.status)),
            ("grokProbeIntervalS", .int(grok.interval)),
            ("grokProbeCooldownLeftS", grok.cooldownLeft.map(JSONValue.int) ?? .null),
            ("grokProbeAgeS", grok.age.map(JSONValue.int) ?? .null),
            ("cursorProbe", .string(cursor.status)),
            ("cursorProbeIntervalS", .int(cursor.interval)),
            ("cursorProbeCooldownLeftS", cursor.cooldownLeft.map(JSONValue.int) ?? .null),
            ("cursorProbeAgeS", cursor.age.map(JSONValue.int) ?? .null),
        ]
        let usageFields: [(String, JSONValue)] = [
            ("claudeLocalUsage", .string(claudePlanUsageStatus(now: wall))),
            ("claudeStatusline", statuslineJSON(now: wall)),
            ("quotaRegressions", quotaRegressionsJSON(now: wall)),
            ("usageComputeOk", .bool(failingSince == nil)),
            ("usageComputeFailingForS", failingSince.map { .int(max(0, Int((mono - $0).rounded(.towardZero)))) } ?? .null),
            ("usageTotals", currentTokens().object?["usageTotals"] ?? .null),
            ("maxTrackerSaveOk", .bool(saveFailing == nil)),
            ("maxTrackerSaveFailingForS", saveFailing.map { .int(max(0, Int((mono - $0).rounded(.towardZero)))) } ?? .null),
            ("discovery", .object(discoveryPairs)),
        ]
        let interactions: [(String, JSONValue)] = [
            ("claude", .bool(environment.claudeInteractions)),
            ("codex", .bool(environment.codexInteractions)),
            ("detail", .bool(environment.interactionDetail)),
            ("legacyClaudePanelV1", .bool(environment.legacyClaudePanelV1)),
            ("relay", .object(relayPairs)),
            ("agentStatusRelay", .object(agentRelayPairs)),
            ("panel", panelPayload(now: mono)),
            ("transport", .string(transport)),
        ]
        return .object(identity + claudeProbeFields + otherProbes + usageFields + [
            ("interactions", .object(interactions)),
        ])
    }

    /// Status word from Claude Desktop's plan-usage file. A nil URL stays `not_checked`.
    private func claudePlanUsageStatus(now: TimeInterval) -> String {
        guard let url = environment.claudePlanUsageURL else { return "not_checked" }
        guard FileManager.default.fileExists(atPath: url.path) else { return "missing" }
        let size: Int
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let fileSize = values.fileSize else { return "invalid" }
            size = fileSize
        } catch {
            return "invalid"
        }
        if size <= 0 || size > 2 * 1024 * 1024 { return "invalid_size" }
        guard let data = try? Data(contentsOf: url),
              let payload = jsonObject(from: data) else { return "invalid" }
        guard jsonInt(payload["version"]) == 2,
              let samples = payload["samples"] as? [Any], !samples.isEmpty,
              let latest = samples.last as? [String: Any] else { return "unsupported" }
        guard let timestamp = jsonInt(latest["t"]), timestamp > 0,
              let org = latest["org"] as? String,
              let orgBytes = org.data(using: .utf8)?.count, (1...128).contains(orgBytes),
              let usage = latest["u"] as? [String: Any] else { return "invalid" }
        for key in ["fh", "sd"] {
            guard jsonPercent(usage[key]) != nil else { return "invalid" }
        }
        let age = now - Double(timestamp) / 1000
        if age < -60 || age > 20 * 60 { return "stale" }
        return "fresh"
    }

    /// The statusLine sample under the state directory. A missing sample with no
    /// bridge config is `not_installed`, matching tokenserver.
    private func statuslineJSON(now: TimeInterval) -> JSONValue {
        let directory = environment.stateDirectory
        let peeked = StatuslineSample.peek(StatuslineSample.sampleURL(in: directory))
        var status = peeked.status
        if status == "missing",
           !FileManager.default.fileExists(atPath: StatuslineSample.configURL(in: directory).path) {
            status = "not_installed"
        }
        var age: JSONValue = .null
        var version: JSONValue = .null
        if status == "ok" {
            let summary = StatuslineSample.summarize(peeked.document, now: Int(now.rounded(.towardZero)))
            status = summary.status
            if let ageS = summary.ageS { age = .int(ageS) }
            if let versionText = summary.claudeCodeVersion { version = .string(versionText) }
        }
        return .object([
            ("status", .string(status)),
            ("ageS", age),
            ("claudeCodeVersion", version),
            ("bridged", .bool(false)),
            ("account", .string("assumed-single")),
        ])
    }

    private func panelPayload(now: TimeInterval) -> JSONValue {
        lock.lock()
        let seen = panel.lastSeenAt
        let route = panel.lastSeenRoute
        let boot = panel.recoveryBoot
        lock.unlock()
        guard let seen else {
            return .object([("status", .string("waiting"))])
        }
        let age = max(0, Int((now - seen).rounded(.towardZero)))
        return .object([
            ("status", .string(Double(age) <= 15 ? "ready" : "stale")),
            ("ageS", .int(age)),
            ("route", .string(route ?? "")),
            ("httpStallRecoveryBoot", .bool(boot)),
        ])
    }

    private func recordPanel(peer: String, path: String, recovery: [String]) {
        if peer.isEmpty || isLoopbackPeer(peer) { return }
        let now = environment.clock.monotonic()
        let boot = recovery == ["http-stall-v1"]
        lock.lock()
        if panel.candidateHost == peer, let at = panel.candidateAt, now - at <= 10 {
            panel.candidateCount += 1
        } else {
            panel.candidateHost = peer
            panel.candidateCount = 1
        }
        panel.candidateAt = now
        if panel.candidateCount >= 2 {
            panel.lastSeenAt = now
            panel.lastSeenRoute = path
            panel.recoveryBoot = boot
        }
        lock.unlock()
    }

    private func providerJSON(_ provider: MaxTrackerProviderSnapshot) -> JSONValue {
        var pairs: [(String, JSONValue)] = []
        if let label = provider.planLabel { pairs.append(("planLabel", .string(label))) }
        pairs.append(("avgPeakPct", provider.avgPeakPct.map(JSONValue.double) ?? .null))
        pairs.append(("maxWeeksStreak", .int(provider.maxWeeksStreak)))
        pairs.append(("maxWeeks", .int(provider.maxWeeks)))
        pairs.append(("maxDays", .int(provider.maxDays)))
        pairs.append(("weekMaxed", .array(provider.weekMaxed.map(JSONValue.int))))
        pairs.append(("days", .array(provider.days.map { .array($0.map(JSONValue.int)) })))
        return .object(pairs)
    }

    private func quotaRegressionsJSON(now: TimeInterval) -> JSONValue {
        .array(history.quotaRegressions(now: now).map { row in
            JSONValue.object([
                ("provider", .string(row.provider)),
                ("scope", .string(row.scope)),
                ("livePct", .double(row.livePct)),
                ("cachedPct", .double(row.cachedPct)),
                ("resetAt", .int(row.resetAt)),
                ("at", .int(row.at)),
            ])
        })
    }

    private func acceptsUsageTotals(_ request: HTTPRequest) -> Bool {
        (request.header("x-vibepulse-accepts") ?? "").lowercased().contains("usage-totals")
    }

    private func usageTotalsArePlaceholders(_ payload: JSONValue) -> Bool {
        payload.object?["usageTotals"]?.object?["placeholder"] == .bool(true)
    }

    private func hasJSONContentType(_ request: HTTPRequest) -> Bool {
        let values = request.headerValues("content-type")
        guard values.count == 1 else { return false }
        let range = NSRange(values[0].startIndex..., in: values[0])
        return contentTypePattern.firstMatch(in: values[0], options: [], range: range) != nil
    }

    private func hasValidLoopbackHost(_ request: HTTPRequest) -> Bool {
        let hosts = request.headerValues("host")
        guard hosts.count == 1 else { return false }
        return loopbackHost(hosts[0], port: boundOrConfiguredPort())
    }

    private func boundOrConfiguredPort() -> Int {
        lock.lock()
        let bound = boundPort
        lock.unlock()
        return bound == 0 ? port : bound
    }
}

func strippedCodexQuestion(_ item: NormalizedInteraction) -> NormalizedInteraction {
    var copy = item
    copy.recommendedIndex = nil
    copy.options = item.options.map { CodexOption(label: $0.label, description: $0.description) }
    copy.view = [
        ("kind", .string("question")),
        ("options_total", .int(item.options.count)),
        ("marked", .bool(false)),
        ("can_approve", .bool(false)),
    ]
    return copy
}

func codexQuestionBody(verdict: String, normalized: NormalizedInteraction) -> JSONValue {
    if verdict == "approve", let index = normalized.recommendedIndex, normalized.options.indices.contains(index) {
        return .object([
            ("status", .string("answered")),
            ("option_index", .int(index)),
            ("answer", .string(normalized.options[index].label)),
        ])
    }
    return .object([
        ("status", .string("computer")),
        ("reason", .string(verdict)),
    ])
}

func codexPermissionBody(_ verdict: String) -> JSONValue? {
    if verdict == "leave_it" { return nil }
    let decision: JSONValue
    if verdict == "approve" {
        decision = .object([("behavior", .string("allow"))])
    } else if verdict == "deny" {
        decision = .object([
            ("behavior", .string("deny")),
            ("message", .string("Denied from VibePulse")),
        ])
    } else {
        return nil
    }
    return .object([
        ("hookSpecificOutput", .object([
            ("hookEventName", .string("PermissionRequest")),
            ("decision", decision),
        ])),
    ])
}

func claudeHookBody(kind: String, verdict: String, optionIndex: Int?, event: [String: Any]) -> JSONValue? {
    if verdict == "leave_it" { return nil }
    if kind == "question" {
        if verdict == "deny" {
            return .object([
                ("hookSpecificOutput", .object([
                    ("hookEventName", .string("PreToolUse")),
                    ("permissionDecision", .string("deny")),
                    ("permissionDecisionReason", .string("Denied from VibePulse")),
                ])),
            ])
        }
        guard verdict == "approve",
              let input = event["tool_input"] as? [String: Any],
              let questions = input["questions"] as? [[String: Any]],
              let question = questions.first,
              let prompt = question["question"] as? String,
              let options = question["options"] as? [[String: Any]],
              let index = optionIndex, options.indices.contains(index),
              let label = options[index]["label"] as? String
        else { return nil }
        let answers = JSONValue.object([(prompt, .string(label))])
        return .object([
            ("hookSpecificOutput", .object([
                ("hookEventName", .string("PreToolUse")),
                ("permissionDecision", .string("allow")),
                ("updatedInput", .object([
                    ("questions", JSONValue.from(questions)),
                    ("answers", answers),
                ])),
            ])),
        ])
    }
    if kind == "approval" {
        let decision: JSONValue
        if verdict == "approve" {
            decision = .object([("behavior", .string("allow"))])
        } else if verdict == "deny" {
            decision = .object([
                ("behavior", .string("deny")),
                ("message", .string("Denied from VibePulse")),
            ])
        } else {
            return nil
        }
        return .object([
            ("hookSpecificOutput", .object([
                ("hookEventName", .string("PermissionRequest")),
                ("decision", decision),
            ])),
        ])
    }
    return nil
}

func isLoopbackPeer(_ host: String) -> Bool {
    if host.isEmpty { return false }
    let text = host.lowercased()
    if text == "::1" || text == "0:0:0:0:0:0:0:1" { return true }
    if text.hasPrefix("::ffff:") {
        return isLoopbackV4(String(text.dropFirst("::ffff:".count)))
    }
    return isLoopbackV4(text)
}

private func isLoopbackV4(_ host: String) -> Bool {
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4, let first = Int(parts[0]), (0...255).contains(first) else { return false }
    guard parts.allSatisfy({ part in
        guard let value = Int(part), (0...255).contains(value) else { return false }
        return true
    }) else { return false }
    return first == 127
}

func loopbackHost(_ value: String, port: Int) -> Bool {
    let authority = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let host: String
    let portText: String?
    if authority.hasPrefix("[") {
        guard let end = authority.firstIndex(of: "]") else { return false }
        let inside = authority[authority.index(after: authority.startIndex)..<end]
        guard isIPv6Loopback(String(inside)) else { return false }
        let rest = authority[end...]
        if rest.count == 1 {
            host = String(inside)
            portText = nil
        } else if rest.hasPrefix("]:"), rest.count > 2 {
            host = String(inside)
            portText = String(rest.dropFirst(2))
        } else {
            return false
        }
        _ = host
    } else {
        if authority.filter({ $0 == ":" }).count > 1 { return false }
        if let colon = authority.lastIndex(of: ":") {
            let name = String(authority[..<colon])
            let suffix = String(authority[authority.index(after: colon)...])
            if suffix.isEmpty { return false }
            host = name
            portText = suffix
        } else {
            host = authority
            portText = nil
        }
        let folded = host.lowercased()
        if folded != "localhost" && folded != "localhost." && !isLoopbackV4(host) {
            return false
        }
    }
    guard let portText else { return true }
    guard let parsed = Int(portText), parsed == port else { return false }
    return true
}

private func isIPv6Loopback(_ text: String) -> Bool {
    let folded = text.lowercased()
    if folded == "::1" || folded == "0:0:0:0:0:0:0:1" { return true }
    let groups = folded.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard groups.count == 8 else { return false }
    return groups.dropLast().allSatisfy { $0 == "0" || $0 == "0000" } && (groups.last == "1" || groups.last == "0001")
}

func jsonInt(_ value: Any?) -> Int? {
    guard let value else { return nil }
    if type(of: value) == Bool.self { return nil }
    if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
    if let int = value as? Int { return int }
    if let number = value as? NSNumber, !CFNumberIsFloatType(number) { return number.intValue }
    return nil
}

/// A finite 0...100 percent. Bool is not a number.
private func jsonPercent(_ value: Any?) -> Double? {
    guard let value else { return nil }
    if value is Bool { return nil }
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let double = number.doubleValue
    guard double.isFinite, (0...100).contains(double) else { return nil }
    return double
}

private func localISO8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = .current
    return formatter.string(from: date)
}
