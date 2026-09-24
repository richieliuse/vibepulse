import XCTest
import VibePulseSupport
@testable import VibePulseState

final class StateTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testQuotaCacheLoadsFixtureAndRejectsBoolPct() throws {
        let root = try directory()
        let path = root.appendingPathComponent("quota-cache.json")
        let fixture = """
        {"v":1,"records":[{"provider":"codex","scope":"general_weekly","identity":"account-a","pct":46.0,"reset_at":2000,"observed_at":1000,"label":"Work account"},{"provider":"claude","scope":"general_weekly","identity":"account-b","pct":true,"reset_at":2000,"observed_at":1000,"label":null}]}
        """
        try fixture.write(to: path, atomically: true, encoding: .utf8)
        let cache = QuotaCache(path: path, now: { 1500 })
        let latest = cache.latest(provider: "codex", scope: "general_weekly")
        XCTAssertEqual(latest?.pct, 46)
        XCTAssertEqual(latest?.resetAt, 2000)
        XCTAssertEqual(latest?.label, "Work account")
        XCTAssertNil(cache.latest(provider: "claude", scope: "general_weekly"))
        XCTAssertNil(cache.latest(provider: "codex", scope: "general_weekly", now: 2000))
        XCTAssertTrue(cache.put(CachedQuota(provider: "claude", scope: "general_session", identity: "id-1",
                                            pct: 12.5, resetAt: 4000, observedAt: 1600, label: "FABLE · WEEK")))
        let reloaded = QuotaCache(path: path, now: { 1500 })
        XCTAssertEqual(reloaded.latest(provider: "claude", scope: "general_session")?.label, "FABLE · WEEK")
        XCTAssertEqual(reloaded.latest(provider: "codex", scope: "general_weekly")?.pct, 46)
    }

    func testCorruptQuotaFileIsQuarantined() throws {
        let root = try directory()
        let path = root.appendingPathComponent("quota-cache.json")
        try Data("{".utf8).write(to: path)
        let cache = QuotaCache(path: path, now: { 1 })
        XCTAssertNil(cache.latest(provider: "codex", scope: "general_weekly"))
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("quota-cache.json.corrupt-") })
    }

    func testUsageHistoryRoundTripForecastAndDelta() throws {
        let root = try directory()
        let path = root.appendingPathComponent("usage-history.json")
        let fixture = """
        {"v":1,"samples":[{"at":1000,"provider":"claude","window":"week","pct":10.0,"reset":3000},{"at":1900,"provider":"claude","window":"week","pct":11.5,"reset":3000}]}
        """
        try fixture.write(to: path, atomically: true, encoding: .utf8)
        let history = UsageHistory(path: path, now: { 2000 })
        XCTAssertEqual(history.records.count, 2)
        XCTAssertEqual(history.records[0].pct, 10)
        XCTAssertFalse(history.record(provider: "claude", window: "week", pct: 12, resetAt: 3000, at: 2000))
        XCTAssertTrue(history.record(provider: "claude", window: "week", pct: 12, resetAt: 3000, at: 2800))
        XCTAssertEqual(history.deltaSince(provider: "claude", window: "week", since: -700_000, resetAt: 3000, now: 2800), 12)
        let forecast = history.forecast(provider: "claude", window: "week", resetAt: 20_000, now: 10_800)
        XCTAssertEqual(forecast.state, "unavailable")
        XCTAssertTrue(history.record(provider: "claude", window: "week", pct: 0, resetAt: 16_200, at: 0))
        XCTAssertTrue(history.record(provider: "claude", window: "week", pct: 10, resetAt: 16_200, at: 5400))
        XCTAssertTrue(history.record(provider: "claude", window: "week", pct: 20, resetAt: 16_200, at: 10_800))
        let pace = history.forecast(provider: "claude", window: "week", resetAt: 16_200, now: 10_800)
        XCTAssertEqual(pace.state, "at_reset")
        XCTAssertEqual(pace.pctAtReset, 30)
        XCTAssertEqual(pace.paceFactor, 8)
        let saved = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(saved.contains("\"pct\":20.0"))
        XCTAssertTrue(saved.hasSuffix("\n"))
    }

    func testQuotaRegressionsEmptyHistoryIsAnEmptyArray() throws {
        XCTAssertEqual(UsageHistory.sampleInterval, 900)
        XCTAssertEqual(UsageHistory.retention, 691_200)
        XCTAssertEqual(UsageHistory.forecastWindow, 86_400)
        XCTAssertEqual(UsageHistory.minForecastSpan, 5_400)
        XCTAssertEqual(UsageHistory.resetQuantum, 300)

        let root = try directory()
        let path = root.appendingPathComponent("usage-history.json")
        let history = UsageHistory(path: path, now: { 10_000 })
        XCTAssertEqual(history.quotaRegressions(), [])
        XCTAssertEqual(history.quotaRegressions(now: .nan), [])
        XCTAssertEqual(history.quotaRegressions(now: .infinity), [])

        // A stored zero is a measurement. It is not a regression against a missing baseline.
        XCTAssertTrue(history.record(provider: "claude", window: "week", pct: 0, resetAt: 30_000, at: 1_000))
        XCTAssertEqual(history.quotaRegressions(now: 1_000), [])

        XCTAssertTrue(history.record(provider: "claude", window: "week", pct: 60, resetAt: 30_000, at: 2_000))
        XCTAssertEqual(history.quotaRegressions(now: 2_000), [])
        XCTAssertTrue(history.record(provider: "claude", window: "week", pct: 40, resetAt: 30_000, at: 2_900))
        XCTAssertEqual(history.quotaRegressions(now: 2_900), [
            QuotaRegression(provider: "claude", scope: "general_weekly", livePct: 40, cachedPct: 60,
                            resetAt: 30_000, at: 2_900),
        ])
        let object = try XCTUnwrap(history.quotaRegressions(now: 2_900)[0].jsonObject.object)
        XCTAssertEqual(object.keys.sorted(), QuotaRegression.jsonKeys.sorted())
        XCTAssertEqual(QuotaRegression.jsonKeys, ["provider", "scope", "livePct", "cachedPct", "resetAt", "at"])
        XCTAssertEqual(object["provider"], .string("claude"))
        XCTAssertEqual(object["scope"], .string("general_weekly"))
        XCTAssertEqual(object["livePct"], .double(40))
        XCTAssertEqual(object["cachedPct"], .double(60))
        XCTAssertEqual(object["resetAt"], .int(30_000))
        XCTAssertEqual(object["at"], .int(2_900))
        XCTAssertFalse(object.values.contains(.null))

        // Once per reset: a further drop does not add or rewrite the first record.
        XCTAssertTrue(history.record(provider: "claude", window: "week", pct: 30, resetAt: 30_000, at: 4_000))
        XCTAssertEqual(history.quotaRegressions(now: 4_000)[0].livePct, 40)
        XCTAssertEqual(history.quotaRegressions(now: 4_000)[0].cachedPct, 60)
        // A higher reading is not another regression.
        XCTAssertTrue(history.record(provider: "claude", window: "week", pct: 55, resetAt: 30_000, at: 5_000))
        XCTAssertEqual(history.quotaRegressions(now: 5_000).filter { $0.scope == "general_weekly" && $0.provider == "claude" }.count, 1)

        XCTAssertTrue(history.record(provider: "claude", window: "session", pct: 80, resetAt: 30_000, at: 1_000))
        XCTAssertTrue(history.record(provider: "claude", window: "session", pct: 70, resetAt: 30_000, at: 1_900))
        XCTAssertTrue(history.record(provider: "claude", window: "model_week", pct: 12, resetAt: 30_000, at: 8_000))
        XCTAssertTrue(history.record(provider: "claude", window: "model_week", pct: 9, resetAt: 30_000, at: 9_000))
        XCTAssertTrue(history.record(provider: "codex", window: "week", pct: 60, resetAt: 60_000, at: 6_000))
        XCTAssertTrue(history.record(provider: "codex", window: "week", pct: 0, resetAt: 60_000, at: 7_000))

        let feed = history.quotaRegressions(now: 9_000)
        XCTAssertEqual(feed.map(\.scope), ["general_session", "general_weekly", "general_weekly", "model_weekly"])
        XCTAssertEqual(feed.map(\.at), [1_900, 2_900, 7_000, 9_000])
        XCTAssertEqual(feed.map(\.provider), ["claude", "claude", "codex", "claude"])
        XCTAssertEqual(feed[2].livePct, 0)
        XCTAssertEqual(feed[2].cachedPct, 60)
        XCTAssertEqual(feed[3].scope, "model_weekly")

        let reloaded = UsageHistory(path: path, now: { 9_000 })
        XCTAssertEqual(reloaded.quotaRegressions(now: 9_000), feed)
        let saved = try String(contentsOf: path, encoding: .utf8)
        XCTAssertFalse(saved.contains("livePct"))

        // The window reset drops its evidence. A new bucket's first low reading is not a drop from the old one.
        XCTAssertEqual(history.quotaRegressions(now: 30_000).map(\.provider), ["codex"])
        XCTAssertTrue(history.record(provider: "claude", window: "week", pct: 10, resetAt: 90_000, at: 31_000))
        XCTAssertEqual(history.quotaRegressions(now: 31_000).filter { $0.resetAt == 90_000 }, [])
        XCTAssertEqual(history.quotaRegressions(now: 60_000).filter { $0.provider == "codex" }, [])
    }

    func testCorruptUsageHistoryIsQuarantined() throws {
        let root = try directory()
        let path = root.appendingPathComponent("usage-history.json")
        try #"{"v":7,"samples":[]}"#.write(to: path, atomically: true, encoding: .utf8)
        let history = UsageHistory(path: path, now: { 1 })
        XCTAssertTrue(history.records.isEmpty)
        XCTAssertTrue(history.record(provider: "claude", window: "week", pct: 1, resetAt: 100, at: 10))
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("usage-history.json.corrupt-") })
    }

    func testValuePayloadFieldNamesAndOpusPrice() throws {
        let document = """
        {"source":{"generated":"2026-09-08"},"plans":{"claude":{"pro":20,"max5x":100},"codex":{"pro":200}},
        "providers":{"anthropic":{"accounting":"cache_excluded_input","cache_read_multiplier":0.1,
        "cache_write_5m_multiplier":1.25,"cache_write_1h_multiplier":2.0,
        "tier_multipliers":{"standard":1.0,"batch":0.5},
        "models":{"claude-opus-5":{"input":5.0,"output":25.0,"cache_read":0.5,"cache_write_5m":6.25,"cache_write_1h":10.0}}},
        "openai":{"accounting":"cache_included_input","cache_read_multiplier":0.1,"cache_write_5m_multiplier":1.25,
        "models":{"gpt-5.6-sol":{"input":5.0,"output":30.0,"cache_read":0.5,"cache_write_5m":6.25}}}}}
        """
        let table = try PriceTable(document: StrictJSON.parse(Data(document.utf8)).get())
        let usage = """
        {"input_tokens":2,"output_tokens":4,"cache_read_input_tokens":23655,
        "cache_creation_input_tokens":8246,"cache_creation":{"ephemeral_5m_input_tokens":8246,"ephemeral_1h_input_tokens":0},
        "service_tier":"standard"}
        """
        let parsedUsage = try StrictJSON.parse(Data(usage.utf8)).get()
        let priced = table.price(model: "claude-opus-5", usage: parsedUsage)
        XCTAssertEqual(priced.unpricedTokens, 0)
        XCTAssertEqual(priced.usd, 0.063475, accuracy: 1e-12)
        XCTAssertEqual(table.price(model: "missing", usage: parsedUsage).unpricedTokens, 31907)
        let payload = buildPayload(valueUSD: 312, unpricedTokens: 0, pricedTokens: 5_000_000,
                                   claudePlan: "max5x", planCosts: ["claude": .double(100)], table: table)
        XCTAssertEqual(payload.keys, [
            "value_usd", "plan_usd", "cost_source", "basis", "prices_as_of", "unpriced_token_share", "state", "multiple",
        ])
        XCTAssertEqual(payload["state"], .string("ok"))
        XCTAssertEqual(payload["multiple"], .double(3.12))
        XCTAssertEqual(payload["cost_source"], .string("configured"))
        XCTAssertEqual(payload["basis"], .string("list API prices"))
        XCTAssertEqual(payload["prices_as_of"], .string("2026-09-08"))
        XCTAssertEqual(table.planCost(provider: "codex", plan: "pro").cost, 200)
        XCTAssertEqual(table.planCost(provider: "claude", plan: "pro", override: .bool(true)).source, "default")
    }

    func testConfigRoundTripAndStrictBool() throws {
        let root = try directory()
        let path = root.appendingPathComponent("config.json")
        let loaded = try VibePulseConfig.load(from: path)
        XCTAssertFalse(loaded.claudeInteractions)
        let config = try VibePulseConfig(claudeInteractions: true, interactionRelayURL: "https://relay.example",
                                         interactionMailbox: "vp_A1b2C3d4E5f6G7h8")
        try config.save(to: path)
        let text = try String(contentsOf: path, encoding: .utf8)
        XCTAssertEqual(text, #"{"agent_status_relay":false,"claude_interactions":true,"codex_interactions":false,"interaction_detail":false,"interaction_mailbox":"vp_A1b2C3d4E5f6G7h8","interaction_relay":false,"interaction_relay_url":"https://relay.example","legacy_claude_panel_v1":false}"# + "\n")
        let again = try VibePulseConfig.load(from: path)
        XCTAssertTrue(again.claudeInteractions)
        XCTAssertEqual(again.interactionRelayURL, "https://relay.example")
        try #"{"claude_interactions":1}"#.write(to: path, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try VibePulseConfig.load(from: path))
        try #"{"claude_interactions":true,"claude_interactions":false}"#.write(to: path, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try VibePulseConfig.load(from: path)) { error in
            XCTAssertEqual((error as? ConfigError)?.message, "duplicate configuration key: claude_interactions")
        }
    }

    func testMaxTrackerFixtureRoundTripAndDayRounding() throws {
        let root = try directory()
        let path = root.appendingPathComponent("max-tracker.json")
        let fixture = """
        {"claude":{"v":1,"days":{"2026-08-11":{"pct":40,"act":true,"lvl":1},"2026-08-12":{"pct":100,"act":true,"lvl":2}},"weeks":{"2026-W32":true},"backfill":{"123":{"offset":10,"size":20,"done":false,"discarding":false}}},"codex":{"v":1,"days":{},"weeks":{},"backfill":{}},"extra":1}
        """
        try fixture.write(to: path, atomically: true, encoding: .utf8)
        let store = MaxTrackerStore(path: path)
        let shot = store.snapshot(today: "2026-08-12", plans: ["claude": "max20x", "codex": "nope"])
        XCTAssertEqual(shot.v, 1)
        XCTAssertEqual(shot.weeks, 20)
        XCTAssertEqual(shot.stale, false)
        XCTAssertEqual(shot.codingStreakDays, 2)
        XCTAssertEqual(shot.claude.planLabel, "MAX 20X")
        XCTAssertNil(shot.codex.planLabel)
        XCTAssertEqual(shot.claude.days.count, 140)
        XCTAssertEqual(shot.codex.weekMaxed.count, 20)
        XCTAssertEqual(shot.claude.maxDays, 1)
        XCTAssertEqual(MaxTrackerStore.roundDayPct(0.5), 1)
        XCTAssertEqual(MaxTrackerStore.roundDayPct(2.5), 3)
        XCTAssertEqual(MaxTrackerStore.roundDayPct(99.96), 99)
        XCTAssertEqual(MaxTrackerStore.roundDayPct(100), 100)
        XCTAssertEqual(MaxTrackerStore.volumeLevels(["a": 1, "b": 2, "c": 3, "d": 4, "e": 5, "f": 6]),
                       ["a": 0, "b": 0, "c": 1, "d": 1, "e": 2, "f": 2])
        store.observeVolume(provider: "claude", date: "2026-08-12", tokens: 500)
        try store.save(today: "2026-08-12")
        let raw = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"v\":1"))
        XCTAssertFalse(raw.contains("\"vol\""))
        XCTAssertTrue(raw.contains("\"offset\":10"))
        let reloaded = MaxTrackerStore(path: path)
        XCTAssertEqual(reloaded.snapshot(today: "2026-08-12").codingStreakDays, 2)
        XCTAssertEqual(CivilDate.parse("2026-08-12")?.weekKey, "2026-W33")
        XCTAssertEqual(CivilDate.parse("2025-12-29")?.weekKey, "2026-W01")
    }

    func testCorruptMaxTrackerIsQuarantined() throws {
        let root = try directory()
        let path = root.appendingPathComponent("max-tracker.json")
        try #"{"claude":[],"codex":{}}"#.write(to: path, atomically: true, encoding: .utf8)
        let store = MaxTrackerStore(path: path)
        XCTAssertNil(store.snapshot(today: "2026-08-12").codingStreakDays)
        try store.save(today: "2026-08-12")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("max-tracker.json.corrupt-") })
        XCTAssertTrue(names.contains("max-tracker.json"))
    }

    func testParsePlanCostsMatchesPythonRules() throws {
        XCTAssertEqual(try parsePlanCosts(entries: ["claude=200", "codex=20", " Claude = 1e2 ", "cursor=1_000"]),
                       ["claude": 100, "codex": 20, "cursor": 1000])
        XCTAssertEqual(try parsePlanCosts(entries: ["claude=1_000.50"]), ["claude": 1000.5])
        XCTAssertEqual(try parsePlanCosts(entries: [], legacyClaude: 100), ["claude": 100])
        XCTAssertEqual(try parsePlanCosts(entries: ["claude=250"], legacyClaude: 100), ["claude": 250])
        XCTAssertEqual(try parsePlanCosts(entries: ["codex=20"], legacyClaude: 100), ["claude": 100, "codex": 20])
        for bad in ["claude", "claude=", "claude=abc", "claude=0", "claude=-5", "=200", "claude=inf", "claude=nan"] {
            XCTAssertThrowsError(try parsePlanCosts(entries: [bad]), bad)
        }
        XCTAssertThrowsError(try parsePlanCosts(entries: ["=200"])) { error in
            XCTAssertEqual((error as? PlanCostError)?.message,
                           "--plan expects PROVIDER=USD, got '=200' (for example: --plan claude=200)")
        }
        XCTAssertThrowsError(try parsePlanCosts(entries: ["claude=0"])) { error in
            XCTAssertEqual((error as? PlanCostError)?.message,
                           "--plan claude needs a positive monthly cost in USD, got '0'")
        }
        XCTAssertThrowsError(try parsePlanCosts(entries: [], legacyClaude: 0))
        XCTAssertThrowsError(try parsePlanCosts(entries: [], legacyClaude: -1))
        XCTAssertThrowsError(try parsePlanCosts(entries: [], legacyClaude: .infinity))
        XCTAssertThrowsError(try parsePlanCosts(entries: [], legacyClaude: .nan)) { error in
            XCTAssertEqual((error as? PlanCostError)?.message, "--plan-cost-usd must be a positive number, got nan")
        }
    }

    func testConfigLockIsHeldAcrossSaveAndWaits() throws {
        let root = try directory()
        let path = root.appendingPathComponent("config.json")
        try configLock(path) {
            try configLock(path) {
                let loaded = try VibePulseConfig.load(from: path)
                XCTAssertFalse(loaded.claudeInteractions)
            }
        }
        let gate = LockGate()
        let lockURL = root.appendingPathComponent(".config.json.lock")
        DispatchQueue.global().async {
            do {
                try configLock(path) {
                    let mode = (try FileManager.default.attributesOfItem(atPath: lockURL.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
                    gate.recordMode(mode & 0o777)
                    gate.append("a")
                    gate.signalEntered()
                    gate.waitRelease()
                    var config = try VibePulseConfig.load(from: path)
                    config.codexInteractions = true
                    try config.save(to: path)
                    gate.append("a-out")
                }
            } catch {
                gate.fail(error)
                gate.signalEntered()
            }
        }
        XCTAssertTrue(gate.waitEntered())
        XCTAssertNil(gate.errorText())
        XCTAssertEqual(gate.mode, 0o600)
        DispatchQueue.global().async {
            gate.signalStarted()
            do {
                try configLock(path) {
                    gate.markSecond()
                    var config = try VibePulseConfig.load(from: path)
                    gate.recordCodex(config.codexInteractions)
                    config.claudeInteractions = true
                    try config.save(to: path)
                    gate.append("b")
                }
            } catch {
                gate.fail(error)
            }
            gate.signalFinished()
        }
        XCTAssertTrue(gate.waitStarted())
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertFalse(gate.secondEntered)
        XCTAssertEqual(gate.snapshot(), ["a"])
        gate.signalRelease()
        XCTAssertTrue(gate.waitFinished())
        XCTAssertNil(gate.errorText())
        XCTAssertTrue(gate.secondEntered)
        XCTAssertTrue(gate.sawCodex)
        XCTAssertEqual(gate.snapshot(), ["a", "a-out", "b"])
        let saved = try VibePulseConfig.load(from: path)
        XCTAssertTrue(saved.claudeInteractions)
        XCTAssertTrue(saved.codexInteractions)

        let target = root.appendingPathComponent("unrelated")
        try Data("do not touch".utf8).write(to: target)
        try FileManager.default.removeItem(at: lockURL)
        try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: target)
        var ran = false
        XCTAssertThrowsError(try configLock(path) { ran = true }) { error in
            XCTAssertEqual((error as? ConfigError)?.message, "configuration lock must not be a symbolic link")
        }
        XCTAssertFalse(ran)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "do not touch")
        try FileManager.default.removeItem(at: lockURL)
        let again = try configLock(path) { try VibePulseConfig.load(from: path) }
        XCTAssertTrue(again.claudeInteractions)
    }

    func testBackfillStepReadsBoundedJsonl() throws {
        let root = try directory()
        let path = root.appendingPathComponent("max-tracker.json")
        let missing = root.appendingPathComponent("missing")
        XCTAssertFalse(MaxTrackerStore(path: path, codexRoot: missing, claudeRoot: missing).backfillStep())
        let day = CivilDate.today().adding(days: -45).isoString
        let codexRoot = root.appendingPathComponent("codex", isDirectory: true)
        let claudeRoot = root.appendingPathComponent("claude", isDirectory: true)
        let codexFile = codexRoot.appendingPathComponent("2026/08/07/rollout-a.jsonl")
        let claudeFile = claudeRoot.appendingPathComponent("project/session.jsonl")
        try FileManager.default.createDirectory(at: codexFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        func rollout(_ pct: Int) -> String {
            #"{"timestamp":"\#(day)T12:00:00","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":\#(pct),"window_minutes":300}}}}"#
        }
        let line1 = Data((rollout(10) + "\n").utf8)
        let line2 = Data((rollout(49) + "\n").utf8)
        try (line1 + line2).write(to: codexFile)
        let claudeLine = #"{"timestamp":"\#(day)T12:00:00","message":{"usage":{"input_tokens":100}}}"# + "\n"
        try claudeLine.write(to: claudeFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -40 * 86_400)], ofItemAtPath: claudeFile.path)
        let store = MaxTrackerStore(path: path, codexRoot: codexRoot, claudeRoot: claudeRoot)
        XCTAssertTrue(store.backfillStep(budgetBytes: line1.count + 2))
        let index = try dayIndex(day)
        var shot = store.snapshot(today: day)
        XCTAssertEqual(shot.codex.avgPeakPct, 10)
        XCTAssertEqual(shot.codex.days[index], [10, 0])
        XCTAssertEqual(shot.claude.days[index], [-1, 0])
        XCTAssertEqual(shot.codingStreakDays, 1)
        try store.save(today: day)
        let saved = try Data(contentsOf: path)
        let document = try StrictJSON.parse(saved).get()
        let inode = (try FileManager.default.attributesOfItem(atPath: codexFile.path)[.systemFileNumber] as? NSNumber)?.int64Value
        let entry = document.object?["codex"]?.object?["backfill"]?.object?[String(inode ?? -1)]?.object
        XCTAssertEqual(entry?["offset"]?.int, line1.count)
        XCTAssertEqual(entry?["size"]?.int, line1.count + line2.count)
        XCTAssertEqual(entry?["done"]?.bool, false)
        XCTAssertEqual(entry?["discarding"]?.bool, false)
        XCTAssertFalse(store.backfillStep())
        shot = store.snapshot(today: day)
        XCTAssertEqual(shot.codex.avgPeakPct, 49)
        XCTAssertEqual(shot.codex.days[index], [49, 0])
        XCTAssertEqual(shot.claude.days[index], [-1, 0])
        XCTAssertFalse(store.backfillStep())
        let reloaded = MaxTrackerStore(path: path, codexRoot: codexRoot, claudeRoot: claudeRoot)
        XCTAssertFalse(reloaded.backfillStep())
        XCTAssertEqual(reloaded.snapshot(today: day).codex.avgPeakPct, 49)
    }

    private func dayIndex(_ day: String) throws -> Int {
        let date = try XCTUnwrap(CivilDate.parse(day))
        let monday = date.adding(days: 1 - date.isoWeekday)
        let start = monday.adding(days: -7 * (MaxTrackerStore.windowWeeks - 1))
        return date.serial - start.serial
    }
}

private final class LockGate: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    private var errorMessage: String?
    private let entered = DispatchSemaphore(value: 0)
    private let started = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private var modeBits = 0
    private var second = false
    private var codex = false

    func append(_ value: String) {
        lock.lock()
        items.append(value)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    func fail(_ error: Error) {
        lock.lock()
        errorMessage = String(describing: error)
        lock.unlock()
    }

    func errorText() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return errorMessage
    }

    func recordMode(_ mode: Int) {
        lock.lock()
        modeBits = mode
        lock.unlock()
    }

    var mode: Int {
        lock.lock()
        defer { lock.unlock() }
        return modeBits
    }

    func markSecond() {
        lock.lock()
        second = true
        lock.unlock()
    }

    var secondEntered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return second
    }

    func recordCodex(_ value: Bool) {
        lock.lock()
        codex = value
        lock.unlock()
    }

    var sawCodex: Bool {
        lock.lock()
        defer { lock.unlock() }
        return codex
    }

    func signalEntered() { entered.signal() }
    func waitEntered() -> Bool { entered.wait(timeout: .now() + 3) == .success }
    func signalStarted() { started.signal() }
    func waitStarted() -> Bool { started.wait(timeout: .now() + 3) == .success }
    func signalRelease() { release.signal() }
    func waitRelease() { _ = release.wait(timeout: .now() + 3) }
    func signalFinished() { finished.signal() }
    func waitFinished() -> Bool { finished.wait(timeout: .now() + 3) == .success }
}
