import Foundation
import XCTest
import VibePulseSupport
@testable import VibePulseProviders

final class ProviderTests: XCTestCase {
    func testClaudeUsageBodyMapsSessionWeekAndNamedModel() throws {
        let now = 1_786_531_200.0
        let parsed = ClaudeLimits.parseUsageLimits(try body([
            "limits": [
                ["kind": "session", "percent": 2, "resets_at": "2026-08-12T16:00:00+00:00"],
                ["kind": "weekly_all", "percent": 30, "resets_at": "2026-08-14T06:00:00+00:00"],
                [
                    "kind": "weekly_scoped", "percent": 41, "resets_at": "2026-08-14T06:00:00+00:00",
                    "is_active": true, "scope": ["model": ["display_name": "Fable"]],
                ],
            ],
        ]), now: now)

        XCTAssertEqual(parsed.sessionPct, 2.0)
        XCTAssertEqual(parsed.sessionResetAt, 1_786_550_400)
        XCTAssertEqual(parsed.sessionResetMin, 320)
        XCTAssertEqual(parsed.weekPct, 30.0)
        XCTAssertEqual(parsed.weekResetAt, 1_786_687_200)
        XCTAssertEqual(parsed.weekResetMin, 2600)
        XCTAssertEqual(parsed.weekObservedAt, 1_786_531_200)
        XCTAssertEqual(parsed.weekIdentity, StateFiles.quotaIdentity(provider: "claude", scope: "general_weekly"))
        XCTAssertEqual(parsed.modelPct, 41.0)
        XCTAssertEqual(parsed.modelLabel, "FABLE · WEEK")
        XCTAssertEqual(parsed.modelResetAt, 1_786_687_200)
        XCTAssertEqual(parsed.modelIdentity, StateFiles.quotaIdentity(provider: "claude", scope: "model_weekly"))
        XCTAssertTrue(parsed.unknownBuckets.isEmpty)
    }

    func testClaudeUsageBodyKeepsRealConsumptionAndDropsUntouchedPools() throws {
        let now = 1_786_531_200.0
        let inactive = ClaudeLimits.parseUsageLimits(try body([
            "limits": [[
                "kind": "weekly_scoped", "percent": 11, "resets_at": "2026-08-21T06:00:00+00:00",
                "is_active": false,
                "scope": ["model": ["id": NSNull(), "display_name": "Fable"], "surface": NSNull()],
            ]],
        ]), now: now)
        XCTAssertEqual(inactive.modelPct, 11.0)
        XCTAssertEqual(inactive.modelLabel, "FABLE · WEEK")

        let untouched = ClaudeLimits.parseUsageLimits(try body([
            "limits": [[
                "kind": "weekly_scoped", "percent": 0, "resets_at": "2026-08-21T06:00:00+00:00",
                "is_active": false, "scope": ["model": ["display_name": "Fable"]],
            ]],
        ]), now: now)
        XCTAssertNil(untouched.modelPct)
        XCTAssertNil(untouched.modelLabel)

        let activeZero = ClaudeLimits.parseUsageLimits(try body([
            "limits": [[
                "kind": "weekly_scoped", "percent": 0, "resets_at": "2026-08-21T06:00:00+00:00",
                "is_active": true, "scope": ["model": ["display_name": "  Opus  "]],
            ]],
        ]), now: now)
        XCTAssertEqual(activeZero.modelPct, 0.0)
        XCTAssertEqual(activeZero.modelLabel, "OPUS · WEEK")

        let unnamed = ClaudeLimits.parseUsageLimits(try body([
            "limits": [[
                "kind": "weekly_scoped", "percent": 5, "resets_at": "2026-08-21T06:00:00+00:00",
                "scope": ["model": ["display_name": "Sonnet"]],
            ]],
        ]), now: now)
        XCTAssertEqual(unnamed.modelLabel, "SONNET · WEEK")

        let future = ClaudeLimits.parseUsageLimits(try body([
            "limits": [[
                "kind": "weekly_scoped", "percent": 41, "resets_at": "2026-08-14T06:00:00+00:00",
                "is_active": true, "scope": ["model": ["display_name": "Future"]],
            ]],
        ]), now: now)
        XCTAssertNil(future.modelPct)
        XCTAssertNil(future.modelLabel)

        let rejected = ClaudeLimits.parseUsageLimits(try body([
            "limits": [
                ["kind": "session", "percent": true, "resets_at": "2026-08-21T06:00:00+00:00"],
                ["kind": "weekly_all", "percent": 101, "resets_at": "2026-08-21T06:00:00+00:00"],
                ["kind": "weekly_all", "percent": 10, "resets_at": "2020-01-01T00:00:00Z"],
                ["kind": "weekly_all", "percent": -1, "resets_at": "2026-08-21T06:00:00+00:00"],
                "not-an-object",
            ],
        ]), now: now)
        XCTAssertNil(rejected.sessionPct)
        XCTAssertNil(rejected.weekPct)
        XCTAssertNil(ClaudeLimits.parseUsageLimits(Data("[]".utf8), now: now).weekPct)
        XCTAssertNil(ClaudeLimits.parseUsageLimits(Data("{\"limits\":{}}".utf8), now: now).weekPct)
    }

    func testClaudeRateLimitHeadersScaleFractionsAndKeepUnknownBuckets() {
        let now = 1_800_000_000.0
        let labels = ["7d_fable": "FABLE · WEEK", "7d_opus": "OPUS · WEEK", "7d_sonnet": "SONNET · WEEK"]
        for (bucket, label) in labels {
            let parsed = ClaudeLimits.parseLimitHeaders(limitHeaders(modelBucket: bucket), now: now)
            XCTAssertEqual(parsed.modelLabel, label, bucket)
            XCTAssertEqual(parsed.modelPct, 73.0, bucket)
            XCTAssertEqual(parsed.sessionPct, 12.0, bucket)
            XCTAssertEqual(parsed.sessionResetMin, 60, bucket)
            XCTAssertEqual(parsed.weekPct, 47.0, bucket)
            XCTAssertEqual(parsed.weekResetMin, 120, bucket)
            XCTAssertEqual(parsed.modelResetMin, 180, bucket)
            XCTAssertEqual(parsed.weekObservedAt, 1_800_000_000, bucket)
            XCTAssertEqual(parsed.modelObservedAt, 1_800_000_000, bucket)
            XCTAssertEqual(parsed.weekIdentity, StateFiles.quotaIdentity(provider: "claude", scope: "general_weekly"), bucket)
            XCTAssertEqual(parsed.modelIdentity, StateFiles.quotaIdentity(provider: "claude", scope: "model_weekly"), bucket)
        }

        let generic = ClaudeLimits.parseLimitHeaders(limitHeaders(modelBucket: "7d_model"), now: now)
        XCTAssertEqual(generic.modelPct, 73.0)
        XCTAssertNil(generic.modelLabel)

        let weekOnly = ClaudeLimits.parseLimitHeaders([
            "anthropic-ratelimit-unified-5h-utilization": "12",
            "anthropic-ratelimit-unified-7d-utilization": "47",
        ], now: now)
        XCTAssertEqual(weekOnly.sessionPct, 12.0)
        XCTAssertEqual(weekOnly.weekPct, 47.0)
        let namedWeek = ClaudeLimits.parseLimitHeaders([
            "anthropic-ratelimit-unified-week-utilization": "9",
        ], now: now)
        XCTAssertEqual(namedWeek.weekPct, 9.0)
        XCTAssertNil(weekOnly.modelPct)
        XCTAssertNil(weekOnly.weekIdentity)

        var unknown = limitHeaders(modelBucket: "7d_haiku")
        unknown["anthropic-ratelimit-unified-extra_bucket-utilization"] = "1"
        unknown["anthropic-ratelimit-unified-weird.name-utilization"] = "1"
        unknown["anthropic-ratelimit-unified-...-utilization"] = "1"
        let collected = ClaudeLimits.parseLimitHeaders(unknown, now: now)
        XCTAssertEqual(collected.weekPct, 47.0)
        XCTAssertNil(collected.modelPct)
        XCTAssertEqual(collected.unknownBuckets, ["7d_haiku", "extra_bucket", "weirdname"])

        let scaled = ClaudeLimits.parseLimitHeaders([
            "Anthropic-RateLimit-Unified-5h-Utilization": "0.5",
            "anthropic-ratelimit-unified-5h-resets-at": "3600",
            "anthropic-ratelimit-unified-7d-reset": "2026-08-14T06:00:00Z",
            "anthropic-ratelimit-unified-7d-utilization": "1",
            "anthropic-ratelimit-unified-over-utilization": "1.1",
        ], now: 1_786_531_200)
        XCTAssertEqual(scaled.sessionPct, 50.0)
        XCTAssertEqual(scaled.sessionResetAt, 1_786_534_800)
        XCTAssertEqual(scaled.sessionResetMin, 60)
        XCTAssertEqual(scaled.weekPct, 100.0)
        XCTAssertEqual(scaled.weekResetAt, 1_786_687_200)
        XCTAssertEqual(scaled.weekResetMin, 2600)
        XCTAssertEqual(scaled.unknownBuckets, ["over"])

        let absolute = ClaudeLimits.parseLimitHeaders([
            "anthropic-ratelimit-unified-5h-reset": "1900000000",
            "anthropic-ratelimit-unified-5h-utilization": "3",
            "anthropic-ratelimit-unified-7d-reset": "-5",
        ], now: 1_800_000_000)
        XCTAssertEqual(absolute.sessionResetAt, 1_900_000_000)
        XCTAssertEqual(absolute.sessionResetMin, 1_666_667)
        XCTAssertNil(absolute.weekResetAt)
    }

    func testClaudeOAuthCandidatesComeFromInjectedResults() {
        let command = "/Users/test/Library/Application Support/Claude/claude-code/2.1.219/claude.app/Contents/MacOS/claude CLAUDE_CODE_OAUTH_TOKEN=fresh-process-token"
        XCTAssertEqual(ClaudeOAuthCandidates.processToken(in: command), "fresh-process-token")
        XCTAssertNil(ClaudeOAuthCandidates.processToken(in: "/usr/bin/claude CLAUDE_CODE_OAUTH_TOKEN=nope"))

        let processes = ListedProcesses(
            ids: ["abc", "12", "13"],
            lines: [
                "12": command,
                "13": "/tmp/claude CLAUDE_CODE_OAUTH_TOKEN=other",
            ])
        XCTAssertEqual(ClaudeOAuthCandidates.processToken(using: processes), "fresh-process-token")

        let keychain = """
        {"claudeAiOauth":{"accessToken":"expired-keychain-token","expiresAt":1000}}
        """
        let ordered = ClaudeOAuthCandidates.ordered(
            processToken: "fresh-process-token",
            keychain: KeychainCommandResult(exitCode: 0, stdout: keychain))
        XCTAssertEqual(ordered.map(\.token), ["fresh-process-token", "expired-keychain-token"])
        XCTAssertNil(ordered[0].expiresAtMilliseconds)
        XCTAssertEqual(ordered[1].expiresAtMilliseconds, 1000)
        XCTAssertEqual(
            ClaudeOAuthCandidates.ordered(processToken: "same", keychainToken: "same", keychainExpiresAtMilliseconds: 5).map(\.token),
            ["same"])

        XCTAssertEqual(ClaudeOAuthCandidates.interpret(KeychainCommandResult(failure: .binaryMissing)).reason, "keychain_security_missing")
        XCTAssertEqual(ClaudeOAuthCandidates.interpret(KeychainCommandResult(failure: .timeout)).reason, "keychain_timeout")
        XCTAssertEqual(
            ClaudeOAuthCandidates.interpret(KeychainCommandResult(failure: .spawnFailed, spawnErrorName: "EPERM")).reason,
            "keychain_spawn_failed: EPERM")
        XCTAssertEqual(ClaudeOAuthCandidates.interpret(KeychainCommandResult(exitCode: 44)).reason, "keychain_no_entry")
        XCTAssertEqual(
            ClaudeOAuthCandidates.interpret(KeychainCommandResult(exitCode: 36)).reason,
            "keychain_denied_or_locked (exit 36)")
        XCTAssertEqual(ClaudeOAuthCandidates.interpret(KeychainCommandResult(exitCode: 0, stdout: "nope")).reason, "keychain_malformed")
        XCTAssertEqual(
            ClaudeOAuthCandidates.interpret(KeychainCommandResult(exitCode: 0, stdout: "{\"claudeAiOauth\":{}}")).reason,
            "keychain_entry_without_token")
        XCTAssertNil(ClaudeOAuthCandidates.interpret(KeychainCommandResult(exitCode: 0, stdout: keychain)).reason)

        let now = 1_000_000.0
        XCTAssertEqual(ClaudeOAuthCandidates.credentialSnapshot([], now: now).status, "unavailable")
        XCTAssertEqual(
            ClaudeOAuthCandidates.credentialSnapshot([ClaudeOAuthCandidate(token: "t")], now: now).status,
            "unknown")
        let expired = ClaudeOAuthCandidates.credentialSnapshot(
            [ClaudeOAuthCandidate(token: "t", expiresAtMilliseconds: now * 1000)], now: now)
        XCTAssertEqual(expired.status, "expired")
        XCTAssertEqual(expired.expiresInMin, 0)
        let expiring = ClaudeOAuthCandidates.credentialSnapshot(
            [ClaudeOAuthCandidate(token: "t", expiresAtMilliseconds: (now + 1800) * 1000)], now: now)
        XCTAssertEqual(expiring.status, "expiring")
        XCTAssertEqual(expiring.expiresInMin, 30)
        let ready = ClaudeOAuthCandidates.credentialSnapshot(
            [ClaudeOAuthCandidate(token: "t", expiresAtMilliseconds: (now + 1801) * 1000)], now: now)
        XCTAssertEqual(ready.status, "ready")
        XCTAssertEqual(ready.expiresInMin, 31)
        XCTAssertFalse(String(describing: ready).contains("token"))
    }

    func testCodexRateLimitsMapWhamAndAppServerWindows() throws {
        let wham = try body([
            "rate_limit": [
                "primary_window": ["used_percent": 15, "limit_window_seconds": 18000, "reset_at": 1_900_000_000],
                "secondary_window": ["used_percent": 5, "limit_window_seconds": 604800, "reset_at": 1_900_100_000],
            ],
            "additional_rate_limits": [[
                "limit_name": "GPT-5.3-Codex-Spark",
                "primary_window": ["used_percent": 90, "limit_window_seconds": 604800, "reset_at": 1_900_200_000],
            ]],
        ])
        let mapped = CodexOAuth.parseWhamUsage(wham, observedAt: 1_800_000_000, now: 1_800_000_000)
        XCTAssertEqual(mapped.codexSessionPct, 15.0)
        XCTAssertEqual(mapped.codexSessionWindowMinutes, 300.0)
        XCTAssertEqual(mapped.codexSessionResetMin, 1_666_667)
        XCTAssertEqual(mapped.codexWeekPct, 5.0)
        XCTAssertEqual(mapped.codexWeekWindowMinutes, 10080.0)
        XCTAssertEqual(mapped.codexWeekStale, false)
        XCTAssertEqual(mapped.codexWeekObservedAt, 1_800_000_000)
        XCTAssertEqual(mapped.codexWeekIdentity, StateFiles.quotaIdentity(provider: "codex", scope: "general_weekly"))
        XCTAssertNil(CodexOAuth.appServerBody(try body([
            "rate_limit": ["primary_window": ["used_percent": 10, "limit_window_seconds": 18001, "reset_at": 1_900_000_000]],
        ])))
        XCTAssertNil(CodexOAuth.appServerBody(try body([
            "rate_limit": ["primary_window": ["used_percent": 10, "limit_window_seconds": true, "reset_at": 1_900_000_000]],
        ])))

        let appServer = try body([
            "rateLimits": [
                "limitId": "other", "limitName": NSNull(),
                "primary": ["usedPercent": 10, "windowDurationMins": 10080, "resetsAt": 1_900_000_000],
            ],
            "rateLimitsByLimitId": [
                "codex": [
                    "limitId": "codex", "limitName": NSNull(),
                    "primary": ["usedPercent": 62, "windowDurationMins": 10080, "resetsAt": 1_900_000_000],
                ],
                "codex_bengalfox": [
                    "limitId": "codex_bengalfox", "limitName": "GPT-5.3-Codex-Spark",
                    "primary": ["usedPercent": 0, "windowDurationMins": 10080, "resetsAt": 1_900_100_000],
                ],
            ],
        ])
        let selected = CodexRateLimits.parseResponse(appServer, observedAt: 1_800_000_000, now: 1_800_000_000)
        XCTAssertEqual(selected.codexWeekPct, 62.0)
        XCTAssertEqual(selected.codexWeekResetAt, 1_900_000_000)
        XCTAssertEqual(selected.codexWeekStale, false)
        XCTAssertEqual(selected.codexWeekIdentity, StateFiles.quotaIdentity(provider: "codex", scope: "general_weekly", raw: "codex"))

        let preserved = CodexRateLimits.parseResponse(try body([
            "rateLimits": ["primary": ["usedPercent": 57.0, "windowDurationMins": 10080, "resetsAt": 1_900_000_000]],
        ]), observedAt: 1_899_996_400, now: 1_899_996_400)
        XCTAssertEqual(preserved.codexWeekPct, 57.0)
        XCTAssertEqual(preserved.codexWeekResetAt, 1_900_000_000)
        XCTAssertNil(preserved.codexSessionPct)
        XCTAssertEqual(Int(((Double(preserved.codexWeekResetAt!) - 1_899_996_400) / 60).rounded()), 60)

        XCTAssertEqual(CodexRateLimits.parseResponse(try body([
            "rateLimits": [
                "limitName": "",
                "primary": ["usedPercent": 46, "windowDurationMins": 10080, "resetsAt": 1_900_000_000],
            ],
        ]), observedAt: 1_800_000_000, now: 1_800_000_000).codexWeekPct, 46.0)
        for name in [false, 0, [String](), [String: String]()] as [Any] {
            let named = CodexRateLimits.parseResponse(try body([
                "rateLimits": [
                    "limitName": name,
                    "primary": ["usedPercent": 46, "windowDurationMins": 10080, "resetsAt": 1_900_000_000],
                    "secondary": ["usedPercent": 15, "windowDurationMins": 300, "resetsAt": 1_900_000_000],
                ],
            ]), observedAt: 1_800_000_000, now: 1_800_000_000)
            XCTAssertTrue(named.isEmpty)
        }
        XCTAssertTrue(CodexRateLimits.parseResponse(try body([
            "rateLimits": ["primary": ["usedPercent": 46, "windowDurationMins": 43200, "resetsAt": 1_900_000_000]],
        ]), observedAt: 1_800_000_000, now: 1_800_000_000).isEmpty)
        XCTAssertTrue(CodexRateLimits.parseResponse(try body([
            "rateLimits": ["primary": ["usedPercent": 46, "windowDurationMins": "10080", "resetsAt": 1_900_000_000]],
        ]), observedAt: 1_800_000_000, now: 1_800_000_000).isEmpty)
        XCTAssertTrue(CodexRateLimits.parseResponse(try body([
            "rateLimits": ["primary": ["usedPercent": 15, "windowDurationMins": 300, "resetsAt": 1_900_000_000]],
        ]), observedAt: 1_800_000_000, now: 1_800_000_000).isEmpty)
        XCTAssertTrue(CodexRateLimits.parseResponse(Data("null".utf8), observedAt: 1, now: 1).isEmpty)
    }

    func testCodexRolloutParsersAcceptOnlyTheTokenCountEnvelope() throws {
        let limits: [String: Any] = [
            "limit_id": "synthetic-general",
            "primary": ["used_percent": 15, "window_minutes": 300, "resets_at": 1_900_000_000],
            "secondary": ["used_percent": 5, "window_minutes": 10080, "resets_at": 1_900_100_000],
        ]
        let line = try body([
            "timestamp": "2026-08-07T10:00:00Z",
            "type": "event_msg",
            "payload": ["type": "token_count", "info": NSNull(), "rate_limits": limits],
        ])
        XCTAssertTrue(CodexRollout.rateLimits(in: line))
        let parsed = CodexRollout.parseLine(line, now: 1_800_000_000)
        XCTAssertEqual(parsed.codexSessionPct, 15.0)
        XCTAssertEqual(parsed.codexSessionWindowMinutes, 300.0)
        XCTAssertEqual(parsed.codexWeekPct, 5.0)
        XCTAssertEqual(parsed.codexWeekWindowMinutes, 10080.0)
        XCTAssertEqual(parsed.codexWeekObservedAt, 1_786_096_800)
        XCTAssertEqual(parsed.codexWeekIdentity, StateFiles.quotaIdentity(provider: "codex", scope: "general_weekly", raw: "synthetic-general"))

        let naive = try body([
            "timestamp": "2026-08-07T10:00:00",
            "type": "event_msg",
            "payload": ["type": "token_count", "rate_limits": limits],
        ])
        let utc = CodexRollout.parseLine(naive, now: 1_800_000_000, naiveZone: TimeZone(secondsFromGMT: 0)!)
        let later = CodexRollout.parseLine(naive, now: 1_800_000_000, naiveZone: TimeZone(secondsFromGMT: 3600)!)
        XCTAssertEqual(utc.codexWeekObservedAt, 1_786_096_800)
        XCTAssertEqual(later.codexWeekObservedAt, 1_786_096_800 - 3600)

        let impostors: [[String: Any]] = [
            ["rate_limits": limits],
            ["type": "message", "payload": ["rate_limits": limits]],
            ["type": "event_msg", "payload": ["type": "message", "rate_limits": limits]],
            ["type": "event_msg", "payload": ["type": "token_count", "message": ["rate_limits": limits]]],
            ["type": "event_msg", "payload": ["type": "token_count", "content": "{\"rate_limits\":{}}"]],
        ]
        for impostor in impostors {
            let data = try body(impostor)
            XCTAssertFalse(CodexRollout.rateLimits(in: data))
            XCTAssertTrue(CodexRollout.parseLine(data, now: 1_800_000_000).isEmpty)
        }
        XCTAssertNil(CodexRollout.observationTimestamp(1_786_096_800))
        XCTAssertEqual(CodexRollout.observationTimestamp("2026-08-07T10:00:00Z"), 1_786_096_800)

        let session = try body(["type": "session_meta", "payload": ["id": "file", "session_id": "conversation"]])
        XCTAssertEqual(CodexRollout.sessionID(in: session), "conversation")
        XCTAssertNil(CodexRollout.sessionID(in: try body(["type": "session_meta", "payload": ["session_id": ""]])))
        XCTAssertNil(CodexRollout.sessionID(in: line))
        XCTAssertEqual(CodexRollout.turnModel(in: try body(["type": "turn_context", "payload": ["model": "gpt-5.6-sol"]])), "gpt-5.6-sol")
        XCTAssertNil(CodexRollout.turnModel(in: try body(["type": "turn_context", "payload": ["model": ""]])))

        let usage = try body([
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": [
                    "last_token_usage": ["input_tokens": 10, "output_tokens": 2, "cache_write_input_tokens": 3],
                    "total_token_usage": ["input_tokens": 999],
                ],
            ],
        ])
        XCTAssertEqual(CodexRollout.lastTokenUsage(in: usage), CodexRolloutUsage(inputTokens: 10, outputTokens: 2, cacheWriteInputTokens: 3))
        XCTAssertNil(CodexRollout.lastTokenUsage(in: try body([
            "type": "event_msg",
            "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": 5]]],
        ])))

        let named = try body([
            "timestamp": "2026-08-07T10:00:00Z",
            "type": "event_msg",
            "payload": ["type": "token_count", "rate_limits": [
                "limit_name": "GPT-5.3-Codex-Spark",
                "primary": ["used_percent": 1, "window_minutes": 10080, "resets_at": 1_900_000_000],
            ]],
        ])
        XCTAssertTrue(CodexRollout.parseLine(named, now: 1_800_000_000).isEmpty)
        XCTAssertTrue(CodexRollout.parseLine(try body([
            "timestamp": "2026-08-07T10:00:00Z",
            "type": "event_msg",
            "payload": ["type": "token_count", "rate_limits": [
                "primary": ["used_percent": 46, "window_minutes": 43200, "resets_at": 1_900_000_000],
            ]],
        ]), now: 1_800_000_000).isEmpty)
    }

    func testCodexOAuthMappingRejectsSecretsAndBadWindows() throws {
        XCTAssertEqual(CodexOAuth.usageURL(base: nil), "https://chatgpt.com/backend-api/wham/usage")
        XCTAssertEqual(CodexOAuth.usageURL(base: "  "), "https://chatgpt.com/backend-api/wham/usage")
        XCTAssertEqual(CodexOAuth.usageURL(base: "https://chatgpt.com/backend-api"), "https://chatgpt.com/backend-api/wham/usage")
        XCTAssertEqual(CodexOAuth.usageURL(base: "https://example.com"), "https://example.com/api/codex/usage")
        XCTAssertEqual(CodexOAuth.usageURL(base: "https://example.com:8443/"), "https://example.com:8443/api/codex/usage")
        XCTAssertEqual(
            CodexOAuth.usageURL(base: "https://chatgpt.com/backend-api/wham/usage/"),
            "https://chatgpt.com/backend-api/wham/usage")
        XCTAssertNil(CodexOAuth.usageURL(base: "http://chatgpt.com/backend-api"))
        XCTAssertNil(CodexOAuth.usageURL(base: "https://user:pass@chatgpt.com/backend-api"))
        XCTAssertNil(CodexOAuth.usageURL(base: "https://example.com?x=1"))

        let config = """
        # chatgpt_base_url = "https://evil.example"
        chatgpt_base_url = "https://chatgpt.com/backend-api"
        chatgpt_base_url = 'https://ignored.example' # trailing
        """
        XCTAssertEqual(CodexOAuth.baseURL(fromConfig: config), "https://chatgpt.com/backend-api")
        XCTAssertEqual(CodexOAuth.baseURL(fromConfig: "chatgpt_base_url = 'https://example.com'\n"), "https://example.com")

        XCTAssertEqual(QuotaHTTP.retryAfterSeconds("42", now: 0), 42)
        XCTAssertEqual(QuotaHTTP.retryAfterSeconds("+42", now: 0), 42)
        XCTAssertEqual(QuotaHTTP.retryAfterSeconds("4_2", now: 0), 42)
        XCTAssertEqual(QuotaHTTP.retryAfterSeconds(" 42 ", now: 0), 42)
        XCTAssertEqual(QuotaHTTP.retryAfterSeconds("42.0", now: 0), 0)
        XCTAssertEqual(QuotaHTTP.retryAfterSeconds("-1", now: 0), 0)
        XCTAssertEqual(QuotaHTTP.retryAfterSeconds(nil, now: 0), 0)
        XCTAssertEqual(QuotaHTTP.retryAfterSeconds("Thu, 01 Jan 1970 00:02:00 GMT", now: 0), 120)

        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let expiredToken = jwt(#"{"exp":1700000000}"#)
        let expiredPath = directory.appendingPathComponent("expired.json")
        try """
        {"tokens":{"access_token":"\(expiredToken)","refresh_token":"refresh-secret","account_id":"acct"}}
        """.write(to: expiredPath, atomically: false, encoding: .utf8)
        let expired = CodexOAuth.loadAuth(path: expiredPath, now: 1_700_000_001)
        XCTAssertEqual(expired.status, "expired")
        XCTAssertNil(expired.accessToken)
        XCTAssertEqual(expired.expiresAt, 1_700_000_000.0)
        let expiredText = String(describing: expired)
        XCTAssertFalse(expiredText.contains(expiredToken))
        XCTAssertFalse(expiredText.contains("refresh-secret"))

        let readyToken = jwt(#"{"exp":1900000000}"#)
        let readyPath = directory.appendingPathComponent("ready.json")
        try """
        {"tokens":{"access_token":"\(readyToken)","account_id":"acct"}}
        """.write(to: readyPath, atomically: false, encoding: .utf8)
        let ready = CodexOAuth.loadAuth(path: readyPath, now: 1_800_000_000)
        XCTAssertEqual(ready.status, "ready")
        XCTAssertEqual(ready.accessToken, readyToken)
        XCTAssertEqual(ready.accountID, "acct")
        XCTAssertFalse(String(describing: ready).contains(readyToken))
        XCTAssertEqual(CodexOAuth.tokenFingerprint(readyToken), SHA256.hex(Data(readyToken.utf8)))
        XCTAssertEqual(CodexOAuth.jwtExpiry(readyToken), 1_900_000_000.0)

        let keyOnly = directory.appendingPathComponent("key.json")
        try #"{"OPENAI_API_KEY":"sk-test"}"#.write(to: keyOnly, atomically: false, encoding: .utf8)
        XCTAssertEqual(CodexOAuth.loadAuth(path: keyOnly, now: 1_800_000_000).status, "missing")
        XCTAssertEqual(CodexOAuth.loadAuth(Data(#"{"tokens":{"access_token":"bad token.x.y"}}"#.utf8), now: 1).status, "missing")
        XCTAssertEqual(CodexOAuth.loadAuth(Data(#"{"tokens":{"access_token":"a.b.c","account_id":""}}"#.utf8), now: 1).accountID, nil)
        XCTAssertEqual(CodexOAuth.loadAuth(path: directory.appendingPathComponent("missing.json"), now: 1).status, "missing")
        XCTAssertEqual(CodexOAuth.loadAuth(Data(), now: 1).status, "malformed")
        XCTAssertEqual(CodexOAuth.loadAuth(Data("{}".utf8), now: 1).status, "missing")
    }

    func testCursorJSONKeepsPercentUnitsAndSessionCookie() throws {
        let ready = jwt(#"{"exp":1800000000,"sub":"auth0|user_01ABC"}"#)
        XCTAssertEqual(CursorUsage.decodeToken(utf16LE(ready)), ready)
        XCTAssertEqual(CursorUsage.decodeToken("\"\(ready)\""), ready)
        XCTAssertEqual(CodexOAuth.jwtExpiry(ready), 1_800_000_000.0)
        XCTAssertEqual(
            CursorUsage.sessionCookie(ready),
            "WorkosCursorSessionToken=user_01ABC%3A%3A\(ready)")
        XCTAssertNil(CursorUsage.sessionCookie(jwt(#"{"sub":"auth0|not a user"}"#)))

        let now = 1_700_000_000.0
        XCTAssertEqual(CursorUsage.load(data: nil, now: now).status, "missing")
        XCTAssertEqual(CursorUsage.load(data: Data("not-a-jwt".utf8), now: now).status, "missing")
        let boundary = jwt("{\"exp\":\(Int(now + 60))}")
        XCTAssertEqual(CursorUsage.load(data: Data(boundary.utf8), now: now).status, "expired")
        let fresh = jwt("{\"exp\":\(Int(now + 61))}")
        let reader = MemoryCursor(blob: Data(fresh.utf8))
        let loaded = CursorUsage.load(using: reader, path: "/tmp/state.vscdb", now: now)
        XCTAssertEqual(loaded.status, "ready")
        XCTAssertEqual(loaded.token, fresh)
        XCTAssertEqual(CursorUsage.load(using: MemoryCursor(blob: nil), path: "/tmp/state.vscdb", now: now).status, "missing")

        let summary = try body([
            "billingCycleEnd": "1771077734000",
            "planUsage": ["totalPercentUsed": 99],
            "individualUsage": ["plan": [
                "totalPercentUsed": 0.36,
                "autoPercentUsed": 17.2,
                "apiPercentUsed": 0,
            ]],
        ])
        let fields = CursorUsage.fields(summary: summary, now: now)
        XCTAssertEqual(fields.cursorTotalPct, 0.4)
        XCTAssertEqual(fields.cursorModelsPct, 17.2)
        XCTAssertEqual(fields.cursorThirdPct, 0.0)
        XCTAssertEqual(fields.cursorTotalResetMin, Int(floor((1_771_077_734 - now) / 60)))
        XCTAssertFalse(fields.cursorTotalStale)
        XCTAssertNil(fields.cursorBotPct)
        XCTAssertFalse(fields.cursorBotStale)

        let alternate = CursorUsage.fields(summary: try body([
            "billingCycleEnd": "2026-10-01T00:00:00Z",
            "planUsage": ["totalPercentUsed": 15.48, "apiPercentUsed": 46.4],
        ]), now: now)
        XCTAssertEqual(alternate.cursorTotalPct, 15.5)
        XCTAssertNil(alternate.cursorModelsPct)
        XCTAssertEqual(alternate.cursorThirdPct, 46.4)
        XCTAssertNotNil(alternate.cursorTotalResetMin)

        let clamped = CursorUsage.fields(summary: try body([
            "billingCycleEnd": "2026-10-01T00:00:00Z",
            "planUsage": ["totalPercentUsed": 150, "autoPercentUsed": 1001, "apiPercentUsed": true],
        ]), now: now)
        XCTAssertEqual(clamped.cursorTotalPct, 100.0)
        XCTAssertNil(clamped.cursorModelsPct)
        XCTAssertNil(clamped.cursorThirdPct)

        let blocked = CursorUsage.fields(summary: summary, sand: try body([
            "includedLimitZero": true, "usagePercent": 80,
        ]), now: now)
        XCTAssertNil(blocked.cursorBotPct)

        let liveEnd = 1_790_726_400.0
        let live = CursorUsage.fields(summary: summary, sand: try body([
            "includedLimitZero": false,
            "usagePercent": 12.5,
            "nextResetTimestampUtc": "2026-09-30T00:00:00Z",
        ]), now: now)
        XCTAssertEqual(live.cursorBotPct, 12.5)
        XCTAssertEqual(live.cursorBotResetMin, Int(floor((liveEnd - now) / 60)))
        XCTAssertFalse(live.cursorBotStale)

        let trial = CursorUsage.fields(summary: summary, sand: try body([
            "includedLimitZero": true,
            "sandTrialExpiresAt": "2099-01-01T00:00:00Z",
            "usagePercent": 3,
            "nextResetTimestampUtc": "2099-01-08T00:00:00Z",
        ]), now: now)
        XCTAssertEqual(trial.cursorBotPct, 3.0)
        XCTAssertNil(trial.cursorBotResetMin)

        let flag = CursorUsage.fields(summary: Data("{}".utf8), sand: try body([
            "hasNonZeroIncludedLimit": true,
            "usagePercent": 8,
            "nextResetTimestampUtc": "2026-09-30T00:00:00Z",
        ]), now: now)
        XCTAssertEqual(flag.cursorBotPct, 8.0)
        XCTAssertNil(flag.cursorTotalPct)

        let passed = CursorUsage.fields(summary: try body([
            "billingCycleEnd": "2020-01-01T00:00:00Z",
            "planUsage": ["totalPercentUsed": 20, "autoPercentUsed": 5, "apiPercentUsed": 1],
        ]), now: now)
        XCTAssertNil(passed.cursorTotalPct)
        XCTAssertNil(passed.cursorTotalResetMin)
        XCTAssertFalse(passed.cursorTotalStale)
    }

    func testGrokJSONPrefersAuthOrderAndCreditPercent() throws {
        let raw = """
        {"https://accounts.x.ai/sign-in":{"key":"aaa.other.sig","refresh_token":"do-not-keep","expires_at":"2099-01-01T00:00:00Z"},"https://auth.x.ai::later":{"key":"ccc.later.sig","refresh_token":"do-not-keep","expires_at":"2099-01-01T00:00:00Z"},"https://auth.x.ai::earlier":{"key":"aaa.preferred.sig","refresh_token":"do-not-keep","expires_at":"2099-01-01T00:00:00Z"}}
        """
        XCTAssertEqual(JSON.topLevelKeys(in: Data(raw.utf8)), [
            "https://accounts.x.ai/sign-in",
            "https://auth.x.ai::later",
            "https://auth.x.ai::earlier",
        ])
        XCTAssertEqual(JSON.topLevelKeys(in: Data("{\"a\\u0022b\":1,\"c\":[1,{\"d\":true}]}".utf8)), ["a\"b", "c"])
        let auth = GrokBilling.loadAuth(Data(raw.utf8), now: 1_700_000_000)
        XCTAssertEqual(auth.status, "ready")
        XCTAssertEqual(auth.accessToken, "ccc.later.sig")
        let printed = String(describing: auth)
        XCTAssertFalse(printed.contains("later"))
        XCTAssertFalse(printed.contains("preferred"))
        XCTAssertFalse(printed.contains("do-not-keep"))
        XCTAssertTrue(printed.contains("has_token=true"))

        let expired = """
        {"https://auth.x.ai::tenant":{"key":"header.payload.sig","expires_at":"2020-01-01T00:00:00Z"}}
        """
        let expiredAuth = GrokBilling.loadAuth(Data(expired.utf8), now: 1_700_000_000)
        XCTAssertEqual(expiredAuth.status, "expired")
        XCTAssertNil(expiredAuth.accessToken)
        XCTAssertEqual(
            GrokBilling.loadAuth(Data(#"{"https://auth.x.ai::tenant":{"key":"xai-secret-key","expires_at":"2099-01-01T00:00:00Z"}}"#.utf8), now: 1_700_000_000).status,
            "missing")
        XCTAssertEqual(GrokBilling.loadAuth(Data(), now: 1).status, "malformed")
        XCTAssertEqual(GrokBilling.loadAuth(Data("[]".utf8), now: 1).status, "malformed")
        XCTAssertEqual(GrokBilling.loadAuth(Data(count: GrokBilling.maxAuthBytes + 1), now: 1).status, "malformed")

        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(GrokBilling.loadAuth(path: directory.appendingPathComponent("missing.json"), now: 1).status, "missing")
        XCTAssertEqual(GrokBilling.loadAuth(path: directory, now: 1).status, "unreadable")

        let now = 1_700_000_000.0
        let end = 1_790_121_600.0
        let weekly = GrokBilling.fields(billing: try body([
            "config": [
                "creditUsagePercent": 0.4,
                "onDemandUsed": ["val": 50],
                "onDemandCap": ["val": 100],
                "currentPeriod": ["start": "2026-09-16T00:00:00Z", "end": "2026-09-23T00:00:00Z"],
            ],
        ]), now: now)
        XCTAssertEqual(weekly.grokCreditPct, 0.4)
        XCTAssertEqual(weekly.grokQuotaLabel, "WEEKLY")
        XCTAssertEqual(weekly.grokCreditResetMin, Int(floor((end - now) / 60)))
        XCTAssertFalse(weekly.grokCreditStale)

        let naive = GrokBilling.fields(billing: try body([
            "config": [
                "creditUsagePercent": 1,
                "currentPeriod": ["start": "2026-09-16T00:00:00", "end": "2026-09-23T00:00:00"],
            ],
        ]), now: now)
        XCTAssertEqual(naive.grokCreditPct, 1.0)
        XCTAssertEqual(naive.grokQuotaLabel, "WEEKLY")
        XCTAssertEqual(naive.grokCreditResetMin, weekly.grokCreditResetMin)

        let monthly = GrokBilling.fields(billing: try body([
            "config": [
                "onDemandUsed": ["val": 25],
                "onDemandCap": ["val": 100],
                "billingPeriodStart": "2026-09-01T00:00:00Z",
                "billingPeriodEnd": "2026-10-01T00:00:00Z",
            ],
        ]), now: now)
        XCTAssertEqual(monthly.grokCreditPct, 25.0)
        XCTAssertEqual(monthly.grokQuotaLabel, "MONTHLY")

        XCTAssertNil(GrokBilling.fields(billing: try body([
            "config": ["currentPeriod": ["start": "2026-09-01T00:00:00Z", "end": "2026-09-08T00:00:00Z"]],
        ]), now: now).grokCreditPct)
        XCTAssertNil(GrokBilling.fields(billing: try body([
            "config": ["onDemandUsed": ["val": 10], "onDemandCap": ["val": 0]],
        ]), now: now).grokCreditPct)
        XCTAssertNil(GrokBilling.fields(billing: try body([
            "creditUsagePercent": 12.5,
            "config": [
                "creditUsagePercent": true,
                "onDemandUsed": ["val": 25],
                "onDemandCap": ["val": 100],
            ],
        ]), now: now).grokCreditPct)
        let fromPayload = GrokBilling.fields(billing: try body([
            "creditUsagePercent": 12.5,
            "config": ["currentPeriod": ["start": "2026-09-16T00:00:00Z", "end": "2026-09-23T00:00:00Z"]],
        ]), now: now)
        XCTAssertEqual(fromPayload.grokCreditPct, 12.5)
        XCTAssertEqual(fromPayload.grokQuotaLabel, "WEEKLY")

        let passed = GrokBilling.fields(billing: try body([
            "config": [
                "creditUsagePercent": 90,
                "currentPeriod": ["start": "2026-09-16T00:00:00Z", "end": "2026-09-23T00:00:00Z"],
            ],
        ]), now: end + 1)
        XCTAssertNil(passed.grokCreditPct)
        XCTAssertNil(passed.grokQuotaLabel)
        XCTAssertFalse(passed.grokCreditStale)

        XCTAssertEqual(PercentParsing.quotaLabel(start: nil, end: 100), "CREDITS")
        XCTAssertEqual(PercentParsing.quotaLabel(start: 0, end: 3 * 86400), "CREDITS")
        XCTAssertEqual(PercentParsing.quotaLabel(start: 0, end: 6 * 86400), "WEEKLY")
        XCTAssertEqual(PercentParsing.quotaLabel(start: 0, end: 8 * 86400), "WEEKLY")
        XCTAssertEqual(PercentParsing.quotaLabel(start: 0, end: 27 * 86400), "MONTHLY")
        XCTAssertEqual(PercentParsing.quotaLabel(start: 0, end: 32 * 86400), "MONTHLY")
        XCTAssertEqual(PercentParsing.quotaLabel(start: 10, end: 10), "CREDITS")
    }

    func testQuotaHTTPExchangeRefusesRedirectsAndOversizedBodies() throws {
        let transport = ScriptedHTTP()
        transport.response = QuotaHTTPResponse(status: 200, body: Data(#"{"ok":true}"#.utf8))
        let ok = QuotaHTTP.exchange(url: "https://example.test/usage", headers: ["Accept": "application/json"], transport: transport)
        XCTAssertEqual(ok.status, 200)
        XCTAssertEqual(JSON.bool(ok.payload?["ok"]), true)
        XCTAssertEqual(transport.calls, 1)
        XCTAssertEqual(transport.last?.url, "https://example.test/usage")

        transport.response = QuotaHTTPResponse(status: 200, body: Data("[1,2]".utf8))
        let array = QuotaHTTP.exchange(url: "https://example.test/usage", headers: [:], transport: transport)
        XCTAssertEqual(array.status, 200)
        XCTAssertNil(array.payload)

        transport.response = QuotaHTTPResponse(status: 429, headers: ["Retry-After": "42"], body: Data(#"{"ignored":true}"#.utf8))
        let limited = QuotaHTTP.exchange(url: "https://example.test/usage", headers: [:], now: 0, transport: transport)
        XCTAssertEqual(limited.status, 429)
        XCTAssertNil(limited.payload)
        XCTAssertEqual(limited.retryAfter, 42)

        transport.response = QuotaHTTPResponse(status: 302, headers: ["Location": "https://evil.test", "Retry-After": "Thu, 01 Jan 1970 00:02:00 GMT"])
        let redirect = QuotaHTTP.exchange(url: "https://example.test/usage", headers: [:], now: 0, transport: transport)
        XCTAssertEqual(redirect.status, 302)
        XCTAssertNil(redirect.payload)
        XCTAssertEqual(redirect.retryAfter, 120)
        XCTAssertEqual(transport.calls, 4)

        transport.error = URLError(.timedOut)
        let failed = QuotaHTTP.exchange(url: "https://example.test/usage", headers: [:], transport: transport)
        XCTAssertEqual(failed.status, 0)
        XCTAssertNil(failed.payload)
        XCTAssertEqual(failed.retryAfter, 0)

        transport.error = nil
        transport.response = QuotaHTTPResponse(status: 200, body: Data(count: QuotaHTTP.maxBodyBytes + 1))
        let oversized = QuotaHTTP.exchange(url: "https://example.test/usage", headers: [:], transport: transport)
        XCTAssertEqual(oversized.status, 0)
        XCTAssertNil(oversized.payload)
    }

    func testTranscriptScannerSumsLocalDaysAndDedups() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = localDate(year: 2026, month: 9, day: 15, hour: 15)
        let recent = usageLine(id: "m1", request: "r1", session: "s2", timestamp: naiveStamp(localDate(year: 2026, month: 9, day: 15, hour: 14, minute: 30)), input: 1, output: 2, cacheCreate: 4, cacheRead: 13)
        let midday = usageLine(id: "m2", request: "r2", session: "s2", timestamp: naiveStamp(localDate(year: 2026, month: 9, day: 15, hour: 12)), input: 40)
        let justBeforeHour = usageLine(id: "m4", request: "r4", session: "s4", timestamp: naiveStamp(localDate(year: 2026, month: 9, day: 15, hour: 13, minute: 59, second: 59)), input: 9)
        let onTheHour = usageLine(id: "m5", request: "r5", session: "s3", timestamp: zulu(localDate(year: 2026, month: 9, day: 15, hour: 14)), input: 1)
        let earlier = usageLine(id: "m3", request: "r3", session: "s1", timestamp: naiveStamp(localDate(year: 2026, month: 9, day: 1, hour: 12)), input: 10)
        let monthStart = usageLine(id: "m6", request: "r6", session: "s1", timestamp: naiveStamp(localDate(year: 2026, month: 9, day: 1)), input: 8)
        let previousMonth = usageLine(id: "old", request: "old", session: "s0", timestamp: naiveStamp(localDate(year: 2026, month: 8, day: 31, hour: 23, minute: 59, second: 59)), input: 100)
        let zero = usageLine(id: "zero", request: "zero", session: "s9", timestamp: naiveStamp(now), input: 0)

        try write("a.jsonl", "{\n" + midday + justBeforeHour + earlier + monthStart + zero + previousMonth, in: directory)
        try write("b.jsonl", recent, in: directory)
        try write("copy.jsonl", recent, in: directory)
        try write("nested/c.jsonl", onTheHour, in: directory)
        try write("notes.txt", recent, in: directory)

        let scan = TranscriptScanner().compute(projectsDirectory: directory, now: now)
        XCTAssertTrue(scan.claudeSourcePresent)
        XCTAssertEqual(scan.monthTokens, 88)
        XCTAssertEqual(scan.dayTokens, 70)
        XCTAssertEqual(scan.dayTokensPerHour, 21)
        XCTAssertEqual(scan.daySessions, 3)
        XCTAssertEqual(scan.dictionary["dayTokens"], .int(70))
        XCTAssertEqual(scan.dictionary["claudeSourcePresent"], .bool(true))
    }

    func testTranscriptDedupRequiresBothMessageIdAndRequestId() throws {
        let now = localDate(year: 2026, month: 9, day: 15, hour: 12)
        let stamp = naiveStamp(now)
        let same = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: same) }
        let line = usageLine(id: "shared", request: "req", session: "s", timestamp: stamp, input: 5)
        try write("a.jsonl", line + line, in: same)
        try write("b.jsonl", line, in: same)
        XCTAssertEqual(TranscriptScanner().compute(projectsDirectory: same, now: now).monthTokens, 5)

        let distinct = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: distinct) }
        try write("a.jsonl", usageLine(id: "shared", request: "one", session: "s", timestamp: stamp, input: 5), in: distinct)
        try write("b.jsonl", usageLine(id: "shared", request: "two", session: "s", timestamp: stamp, input: 5), in: distinct)
        XCTAssertEqual(TranscriptScanner().compute(projectsDirectory: distinct, now: now).monthTokens, 10)

        let partialKey = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: partialKey) }
        try write("a.jsonl", usageLine(id: "shared", request: nil, session: "s", timestamp: stamp, input: 5), in: partialKey)
        try write("b.jsonl", usageLine(id: "shared", request: nil, session: "s", timestamp: stamp, input: 5), in: partialKey)
        XCTAssertEqual(TranscriptScanner().compute(projectsDirectory: partialKey, now: now).dayTokens, 10)

        let paths = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: paths) }
        try write("a.jsonl", usageLine(id: "one", request: "r", session: nil, timestamp: stamp, input: 3) + usageLine(id: "two", request: "r2", session: nil, timestamp: stamp, input: 3), in: paths)
        try write("nested/b.jsonl", usageLine(id: "three", request: "r3", session: nil, timestamp: stamp, input: 3), in: paths)
        let sessions = TranscriptScanner().compute(projectsDirectory: paths, now: now)
        XCTAssertEqual(sessions.dayTokens, 9)
        XCTAssertEqual(sessions.daySessions, 2)
    }

    func testTranscriptCacheAppendsPartialLinesAndDropsDeletedFiles() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = localDate(year: 2026, month: 9, day: 15, hour: 12)
        let first = usageLine(id: "first", request: "a", session: "s", timestamp: naiveStamp(now), input: 5)
        let second = usageLine(id: "second", request: "b", session: "s", timestamp: naiveStamp(now), input: 7)
        let url = try write("session.jsonl", first + String(second.prefix(second.count / 2)), in: directory)
        let scanner = TranscriptScanner()
        XCTAssertEqual(scanner.compute(projectsDirectory: directory, now: now).dayTokens, 5)
        try append(String(second.dropFirst(second.count / 2)), to: url)
        XCTAssertEqual(scanner.compute(projectsDirectory: directory, now: now).dayTokens, 12)

        let replacement = FileManager.default.temporaryDirectory.appendingPathComponent("replacement-\(UUID().uuidString).jsonl")
        let rewritten = usageLine(id: "new", request: "c", session: "s", timestamp: naiveStamp(now), input: 7) + String(repeating: "{\"type\":\"noise\"}\n", count: 20)
        try rewritten.write(to: replacement, atomically: false, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)
        XCTAssertEqual(scanner.compute(projectsDirectory: directory, now: now).dayTokens, 7)

        try FileManager.default.removeItem(at: url)
        let emptied = scanner.compute(projectsDirectory: directory, now: now)
        XCTAssertEqual(emptied.dayTokens, 0)
        XCTAssertTrue(emptied.claudeSourcePresent)

        let stale = try write("stale.jsonl", usageLine(id: "stale", request: "s", session: "s", timestamp: naiveStamp(now), input: 50), in: directory)
        try FileManager.default.setAttributes([.modificationDate: localDate(year: 2026, month: 8, day: 1)], ofItemAtPath: stale.path)
        XCTAssertEqual(TranscriptScanner().compute(projectsDirectory: directory, now: now).monthTokens, 0)

        let missing = directory.appendingPathComponent("missing", isDirectory: true)
        let absent = TranscriptScanner().compute(projectsDirectory: missing, now: now)
        XCTAssertFalse(absent.claudeSourcePresent)
        XCTAssertEqual(absent.dayTokens, 0)
        XCTAssertEqual(absent.monthTokens, 0)
        let file = try write("not-a-directory.txt", "x", in: directory)
        XCTAssertFalse(TranscriptScanner().compute(projectsDirectory: file, now: now).claudeSourcePresent)
    }

    func testClaudeProbeRestsOn429SkipsDeadTokensAndHonorsTheLock() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = 1_700_000_000.0
        let transport = ScriptedHTTP()
        let probe = ClaudeProbe(transport: transport, lockPath: directory.appendingPathComponent("probe.lock"), statePath: directory.appendingPathComponent("state.json"))

        transport.queued = [
            .success(QuotaHTTPResponse(status: 429, headers: ["Retry-After": "42"], body: Data(#"{"limits":[]}"#.utf8))),
            .success(QuotaHTTPResponse(status: 200, body: Data(#"{"limits":[{"kind":"weekly_all","percent":30,"resets_at":"2026-08-14T06:00:00+00:00"}]}"#.utf8))),
        ]
        let limited = probe.run(
            candidates: [ClaudeOAuthCandidate(token: "live"), ClaudeOAuthCandidate(token: "second")],
            now: now,
            monotonic: 50)
        XCTAssertNil(limited.limits)
        XCTAssertEqual(limited.status, "usage_http_429 + backoff_until_\(hhmm(now + 600))")
        XCTAssertEqual(limited.cooldownUntil, now + 600)
        XCTAssertEqual(limited.failureStreak, 1)
        XCTAssertEqual(limited.interval, 480)
        XCTAssertEqual(transport.calls, 1)
        XCTAssertEqual(transport.requests[0].url, ClaudeLimits.usageURL)
        XCTAssertEqual(transport.requests[0].method, "GET")
        XCTAssertEqual(transport.requests[0].timeout, 15)
        XCTAssertEqual(transport.requests[0].headers["Authorization"], "Bearer live")
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("state.json"))) as? [String: Any]
        XCTAssertEqual((saved?["cooldown_until"] as? NSNumber)?.doubleValue, now + 600)

        let resting = probe.run(candidates: [ClaudeOAuthCandidate(token: "live")], now: now + 30, monotonic: 80)
        XCTAssertNil(resting.limits)
        XCTAssertEqual(transport.calls, 1)
        XCTAssertEqual(resting.failureStreak, 2)
        XCTAssertEqual(resting.interval, 960)
        XCTAssertEqual(resting.status, limited.status)

        let dated = ClaudeProbe(transport: ScriptedHTTP(), lockPath: directory.appendingPathComponent("date.lock"), statePath: directory.appendingPathComponent("date.json"))
        let datedTransport = ScriptedHTTP()
        let datedProbe = ClaudeProbe(transport: datedTransport, lockPath: directory.appendingPathComponent("date.lock"), statePath: directory.appendingPathComponent("date-state.json"))
        datedTransport.queued = [.success(QuotaHTTPResponse(status: 429, headers: ["Retry-After": "Thu, 01 Jan 1970 00:02:00 GMT"]))]
        XCTAssertEqual(datedProbe.run(candidates: [ClaudeOAuthCandidate(token: "live")], now: now, monotonic: 1).cooldownUntil, now + 600)
        let longTransport = ScriptedHTTP()
        let longProbe = ClaudeProbe(transport: longTransport, lockPath: directory.appendingPathComponent("long.lock"), statePath: directory.appendingPathComponent("long.json"))
        longTransport.queued = [.success(QuotaHTTPResponse(status: 429, headers: ["Retry-After": "900"]))]
        XCTAssertEqual(longProbe.run(candidates: [ClaudeOAuthCandidate(token: "live")], now: now, monotonic: 1).cooldownUntil, now + 900)
        _ = dated

        let persistedUntil = now + 5_000
        let coldDir = directory.appendingPathComponent("cold", isDirectory: true)
        try FileManager.default.createDirectory(at: coldDir, withIntermediateDirectories: true)
        let coldState = coldDir.appendingPathComponent("state.json")
        let coldLock = coldDir.appendingPathComponent("lock")
        try #"{"cooldown_until": \#(persistedUntil)}"#.write(to: coldState, atomically: false, encoding: .utf8)
        let coldTransport = ScriptedHTTP()
        let cold = ClaudeProbe(transport: coldTransport, lockPath: coldLock, statePath: coldState)
        let coldResult = cold.run(candidates: [ClaudeOAuthCandidate(token: "live")], now: now, monotonic: 10)
        XCTAssertEqual(coldTransport.calls, 0)
        XCTAssertEqual(coldResult.status, "usage_http_429 + backoff_until_\(hhmm(persistedUntil)) (persisted)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: coldLock.path))

        let deadTransport = ScriptedHTTP()
        let deadProbe = ClaudeProbe(transport: deadTransport, lockPath: directory.appendingPathComponent("dead.lock"), statePath: directory.appendingPathComponent("dead.json"))
        deadTransport.queued = (0..<9).map { _ in .success(QuotaHTTPResponse(status: 401)) }
        let tokens = (0..<9).map { ClaudeOAuthCandidate(token: "t\($0)") }
        let rejected = deadProbe.run(candidates: tokens, now: now, monotonic: 1)
        XCTAssertEqual(deadTransport.calls, 9)
        XCTAssertEqual(rejected.status, "usage_http_401")
        XCTAssertEqual(deadProbe.deadTokenCount, 8)
        XCTAssertFalse(deadProbe.isDead("t0"))
        XCTAssertTrue(deadProbe.isDead("t1"))
        XCTAssertTrue(deadProbe.isDead("t8"))
        let week = Data(#"{"limits":[{"kind":"weekly_all","percent":30,"resets_at":"2026-08-14T06:00:00+00:00"}]}"#.utf8)
        deadTransport.queued = [.success(QuotaHTTPResponse(status: 200, body: week))]
        let revived = deadProbe.run(candidates: [ClaudeOAuthCandidate(token: "t0")], now: now, monotonic: 2)
        XCTAssertEqual(revived.limits?.weekPct, 30)
        XCTAssertEqual(revived.status, "usage_http_200 + ok")
        XCTAssertEqual(revived.failureStreak, 0)
        XCTAssertEqual(deadTransport.calls, 10)
        let stillDead = deadProbe.run(candidates: [ClaudeOAuthCandidate(token: "t8")], now: now, monotonic: 3)
        XCTAssertEqual(stillDead.status, "token_dead_awaiting_refresh")
        XCTAssertEqual(stillDead.interval, 15)
        XCTAssertEqual(deadTransport.calls, 10)

        let expiredAt = now - 120
        let expired = deadProbe.run(
            candidates: [ClaudeOAuthCandidate(token: "fresh", expiresAtMilliseconds: expiredAt * 1000)],
            now: now,
            monotonic: 4)
        XCTAssertEqual(expired.status, "token_expired_\(hhmm(expiredAt))")
        XCTAssertEqual(expired.interval, 15)
        XCTAssertEqual(deadTransport.calls, 10)

        let empty = ClaudeProbe(transport: ScriptedHTTP(), lockPath: directory.appendingPathComponent("empty.lock"), statePath: directory.appendingPathComponent("empty.json"))
        let missing = empty.run(candidates: [], keychainReason: "keychain_no_entry", now: now, monotonic: 1)
        XCTAssertEqual(missing.status, "no_claude_oauth_token: keychain_no_entry")
        XCTAssertEqual(missing.credential.status, "unavailable")
        XCTAssertEqual(missing.credential.reason, "keychain_no_entry")
        XCTAssertEqual(missing.interval, 15)

        let heldTransport = ScriptedHTTP()
        let heldLock = directory.appendingPathComponent("held.lock")
        let holder = ProbeFileLock.acquire(heldLock)
        let held = ClaudeProbe(transport: heldTransport, lockPath: heldLock, statePath: directory.appendingPathComponent("held.json"))
        heldTransport.queued = [.success(QuotaHTTPResponse(status: 200, body: week))]
        let blocked = held.run(candidates: [ClaudeOAuthCandidate(token: "x")], now: now, monotonic: 1)
        XCTAssertEqual(blocked.status, "probe_held_by_other_instance")
        XCTAssertEqual(heldTransport.calls, 0)
        holder?.release()
        let released = held.run(candidates: [ClaudeOAuthCandidate(token: "x")], now: now, monotonic: 2)
        XCTAssertEqual(heldTransport.calls, 1)
        XCTAssertEqual(released.status, "usage_http_200 + ok")
        held.statuslineBridged = true
        XCTAssertEqual(held.interval, 1800)
    }

    func testClaudeProbeFallsBackToRateLimitHeaders() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = 1_800_000_000.0
        let transport = ScriptedHTTP()
        let probe = ClaudeProbe(transport: transport, lockPath: directory.appendingPathComponent("lock"), statePath: directory.appendingPathComponent("state.json"))
        let fallbackBody = Data(#"{"model": "claude-haiku-4-5", "max_tokens": 0, "messages": [{"role": "user", "content": "ping"}]}"#.utf8)
        transport.queued = [
            .success(QuotaHTTPResponse(status: 200, body: Data(#"{"limits":[]}"#.utf8))),
            .success(QuotaHTTPResponse(status: 200, headers: limitHeaders(modelBucket: "7d_opus"))),
        ]
        let mapped = probe.run(candidates: [ClaudeOAuthCandidate(token: "tok")], now: now, monotonic: 1)
        XCTAssertEqual(mapped.status, "usage_http_200 + no_mapped_limits; fallback_http_200 + ok")
        XCTAssertEqual(mapped.limits?.modelLabel, "OPUS · WEEK")
        XCTAssertEqual(mapped.limits?.sessionPct, 12)
        XCTAssertEqual(mapped.failureStreak, 0)
        XCTAssertEqual(transport.requests[1].url, ClaudeProbe.messagesURL)
        XCTAssertEqual(transport.requests[1].method, "POST")
        XCTAssertEqual(transport.requests[1].body, fallbackBody)
        XCTAssertEqual(transport.requests[1].headers["Authorization"], "Bearer tok")
        XCTAssertFalse(mapped.ratelimitHeaders.isEmpty)

        transport.queued = [
            .success(QuotaHTTPResponse(status: 500)),
            .success(QuotaHTTPResponse(status: 200)),
        ]
        let unmapped = probe.run(candidates: [ClaudeOAuthCandidate(token: "tok")], now: now, monotonic: 2)
        XCTAssertEqual(unmapped.status, "usage_http_500; fallback_http_200 + no_mapped_headers")
        XCTAssertNil(unmapped.limits)
        XCTAssertEqual(unmapped.failureStreak, 1)
        XCTAssertEqual(unmapped.interval, 480)

        transport.queued = [.failure(ProbeBoom()), .failure(ProbeBoom())]
        let failed = probe.run(candidates: [ClaudeOAuthCandidate(token: "tok")], now: now, monotonic: 3)
        XCTAssertEqual(failed.status, "usage_request_failed: ProbeBoom; fallback_failed: ProbeBoom")
        XCTAssertEqual(failed.failureStreak, 2)
        XCTAssertEqual(failed.interval, 960)
        let capped = probe.run(candidates: [], now: now, monotonic: 4)
        XCTAssertEqual(capped.interval, 15)
        _ = probe.run(candidates: [ClaudeOAuthCandidate(token: "tok")], now: now, monotonic: 5)
    }

    func testCodexAppServerAndRolloutScan() throws {
        let source = CodexLimitsSource()
        let now = 1_800_000_000.0
        let limits = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":1,"windowDurationMins":10080,"resetsAt":1900000000}},"rateLimitsByLimitId":{"codex":{"limitId":"codex","limitName":null,"primary":{"usedPercent":62,"windowDurationMins":10080,"resetsAt":1900000000}}}}}"#
        let read = source.readAppServer(lines: ["not json", #"{"id":1,"result":{}}"#, limits], now: now)
        XCTAssertEqual(read.limits.codexWeekPct, 62)
        XCTAssertEqual(read.limits.codexWeekResetAt, 1_900_000_000)
        XCTAssertEqual(read.limits.codexWeekObservedAt, 1_800_000_000)
        XCTAssertEqual(read.sent.count, 3)
        let sent = try read.sent.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        XCTAssertEqual(sent[0]?["method"] as? String, "initialize")
        XCTAssertEqual((sent[0]?["id"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(sent[1]?["method"] as? String, "initialized")
        XCTAssertEqual(sent[2]?["method"] as? String, "account/rateLimits/read")
        XCTAssertEqual((sent[2]?["id"] as? NSNumber)?.intValue, 2)
        let quiet = source.readAppServer(lines: [String](), now: now)
        XCTAssertTrue(quiet.limits.isEmpty)
        XCTAssertEqual(quiet.sent.count, 1)
        XCTAssertEqual(source.readAppServer(lines: [limits], now: now).limits.codexWeekPct, 62)

        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<21 {
            let pct = index == 0 ? 99 : (index == 18 ? 61 : 0)
            let stamp = index == 0 ? "2026-08-07T12:00:00Z" : String(format: "2026-08-07T10:%02d:00Z", index)
            let nameField = (index == 0 || index == 18) ? "" : #","limit_name":"named""#
            let line = #"{"timestamp":"\#(stamp)","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"id-\#(index)"\#(nameField),"primary":{"used_percent":\#(pct),"window_minutes":10080,"resets_at":1900000000}}}}"# + "\n"
            let url = try write("rollout-\(String(format: "%02d", index)).jsonl", line, in: directory)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(index))], ofItemAtPath: url.path)
        }
        let scanned = source.scan(sessionsDirectory: directory, now: now)
        XCTAssertEqual(scanned.codexWeekPct, 61)
        XCTAssertEqual(scanned.codexWeekStale, false)
        XCTAssertEqual(scanned.codexWeekIdentity, StateFiles.quotaIdentity(provider: "codex", scope: "general_weekly", raw: "id-18"))
        XCTAssertFalse((scanned.codexWeekIdentity ?? "").contains("id-18"))

        let pair = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: pair) }
        let older = #"{"timestamp":"2026-08-07T10:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"synthetic-general","primary":{"used_percent":15,"window_minutes":300,"resets_at":1900000000},"secondary":{"used_percent":46,"window_minutes":10080,"resets_at":1900000100}}}}"# + "\n"
        let newer = #"{"timestamp":"2026-08-07T11:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"spark","limit_name":"GPT-5.3-Codex-Spark","primary":{"used_percent":90,"window_minutes":10080,"resets_at":1900000000}}}}"# + "\n"
        let olderURL = try write("rollout-older.jsonl", older, in: pair)
        let newerURL = try write("rollout-newer.jsonl", newer, in: pair)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: olderURL.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: newerURL.path)
        let mixed = source.scan(sessionsDirectory: pair, now: now)
        XCTAssertEqual(mixed.codexWeekPct, 46)
        XCTAssertEqual(mixed.codexWeekResetAt, 1_900_000_100)
        XCTAssertEqual(mixed.codexSessionPct, 15)
        XCTAssertEqual(mixed.codexSessionWindowMinutes, 300)
        XCTAssertEqual(mixed.codexWeekIdentity, StateFiles.quotaIdentity(provider: "codex", scope: "general_weekly", raw: "synthetic-general"))

        let hiddenDir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: hiddenDir) }
        let event = #"{"timestamp":"2026-08-07T10:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"tail","primary":{"used_percent":35,"window_minutes":10080,"resets_at":1900000000}}}}"# + "\n"
        let noise = String(repeating: "{\"type\":\"noise\"}\n", count: 400)
        try write("rollout-hidden.jsonl", event + noise, in: hiddenDir)
        XCTAssertNil(source.scan(sessionsDirectory: hiddenDir, now: now, maxBytes: 1024).codexWeekPct)
        let visibleDir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: visibleDir) }
        try write("rollout-visible.jsonl", noise + event, in: visibleDir)
        XCTAssertEqual(source.scan(sessionsDirectory: visibleDir, now: now, maxBytes: 4096).codexWeekPct, 35)

        let huge = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: huge) }
        var blob = Data(event.utf8)
        let noiseLine = Data("{\"type\":\"noise\"}\n".utf8)
        blob.reserveCapacity(blob.count + noiseLine.count * 70_000)
        for _ in 0..<70_000 { blob.append(noiseLine) }
        try blob.write(to: huge.appendingPathComponent("rollout-huge.jsonl"))
        XCTAssertNil(source.scan(sessionsDirectory: huge, now: now, maxBytes: 2_000_000).codexWeekPct)
    }

    func testCodexMonthValuePricesLastUsageOncePerSession() throws {
        let now = localDate(year: 2026, month: 9, day: 15, hour: 12)
        let stamp = naiveStamp(now)
        func price(_ model: String?, _ usage: CodexRolloutUsage) -> (usd: Double, unpricedTokens: Int) {
            let tokens = max(usage.inputTokens ?? 0, 0) + max(usage.outputTokens ?? 0, 0) + max(usage.cacheWriteInputTokens ?? 0, 0)
            if model == "gpt-5.6-sol" { return (Double(tokens), 0) }
            return (0, tokens)
        }
        let source = CodexLimitsSource()
        let absent = source.monthValue(sessionsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)"), now: now, price: price)
        XCTAssertEqual(absent, CodexMonthTotals())

        let early = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: early) }
        try write("rollout-early.jsonl", codexToken(input: 10, total: 999, stamp: stamp), in: early)
        let unpriced = source.monthValue(sessionsDirectory: early, now: now, price: price)
        XCTAssertEqual(unpriced.usd, 0)
        XCTAssertEqual(unpriced.pricedTokens, 0)
        XCTAssertEqual(unpriced.unpricedTokens, 10)

        let pricedDir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: pricedDir) }
        try write("rollout-a.jsonl", "{ not json\n" + codexTurn("gpt-5.6-sol") + codexToken(input: 10, total: 999, stamp: stamp), in: pricedDir)
        let priced = CodexLimitsSource().monthValue(sessionsDirectory: pricedDir, now: now, price: price)
        XCTAssertEqual(priced.usd, 10)
        XCTAssertEqual(priced.pricedTokens, 10)
        XCTAssertEqual(priced.unpricedTokens, 0)

        let replay = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: replay) }
        try write("rollout-short.jsonl", codexMeta("sess") + codexTurn("gpt-5.6-sol") + codexToken(input: 10, stamp: stamp), in: replay)
        try write("rollout-long.jsonl", codexMeta("sess") + codexTurn("gpt-5.6-sol") + codexToken(input: 25, stamp: stamp), in: replay)
        try write("nested/rollout-other.jsonl", codexMeta("other") + codexTurn("gpt-5.6-sol") + codexToken(input: 4, stamp: stamp), in: replay)
        let once = CodexLimitsSource().monthValue(sessionsDirectory: replay, now: now, price: price)
        XCTAssertEqual(once.pricedTokens, 29)
        XCTAssertEqual(once.usd, 29)

        let alone = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: alone) }
        try write("rollout-a.jsonl", codexTurn("gpt-5.6-sol") + codexToken(input: 10, stamp: stamp), in: alone)
        try write("rollout-b.jsonl", codexTurn("gpt-5.6-sol") + codexToken(input: 4, stamp: stamp), in: alone)
        XCTAssertEqual(CodexLimitsSource().monthValue(sessionsDirectory: alone, now: now, price: price).usd, 14)

        let growing = CodexLimitsSource()
        let growDir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: growDir) }
        let grow = try write("rollout-grow.jsonl", codexTurn("gpt-5.6-sol"), in: growDir)
        XCTAssertEqual(growing.monthValue(sessionsDirectory: growDir, now: now, price: price).usd, 0)
        let complete = codexToken(input: 10, stamp: stamp)
        try append(String(complete.prefix(20)), to: grow)
        XCTAssertEqual(growing.monthValue(sessionsDirectory: growDir, now: now, price: price).usd, 0)
        try append(String(complete.dropFirst(20)), to: grow)
        let finished = growing.monthValue(sessionsDirectory: growDir, now: now, price: price)
        XCTAssertEqual(finished.usd, 10)
        XCTAssertEqual(finished.unpricedTokens, 0)
        try FileManager.default.removeItem(at: grow)
        XCTAssertEqual(growing.monthValue(sessionsDirectory: growDir, now: now, price: price), CodexMonthTotals())

        let staleDir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: staleDir) }
        let stale = try write("rollout-stale.jsonl", codexTurn("gpt-5.6-sol") + codexToken(input: 10, stamp: stamp), in: staleDir)
        try FileManager.default.setAttributes([.modificationDate: localDate(year: 2026, month: 8, day: 1)], ofItemAtPath: stale.path)
        XCTAssertEqual(CodexLimitsSource().monthValue(sessionsDirectory: staleDir, now: now, price: price).usd, 0)

        let zeros = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: zeros) }
        try write("rollout-zero.jsonl", codexTurn("gpt-5.6-sol") + codexToken(input: 10, stamp: stamp), in: zeros)
        let unpaid = CodexLimitsSource().monthValue(sessionsDirectory: zeros, now: now)
        XCTAssertEqual(unpaid.usd, 0)
        XCTAssertEqual(unpaid.unpricedTokens, 0)
        XCTAssertEqual(unpaid.pricedTokens, 10)
    }

    func testSubscriptionProbeMarksTransportStaleAndRestsTenMinutes() throws {
        let wall = 1_700_000_000.0
        let transport = ScriptedHTTP()
        let billing = Data(#"{"config":{"creditUsagePercent":42,"currentPeriod":{"start":"2026-09-16T00:00:00Z","end":"2026-09-23T00:00:00Z"}}}"#.utf8)
        transport.queued = [.success(QuotaHTTPResponse(status: 200, body: billing))]
        let auth = GrokAuth(status: "ready", accessToken: "ccc.ready.sig")
        let probe = SubscriptionProbe(provider: .grok) { now in
            SubscriptionFetch.grok(auth: auth, now: now, transport: transport)
        }
        probe.refresh(monotonic: 1_000, wall: wall)
        let fresh = probe.grokFields(at: wall + 120)
        XCTAssertEqual(fresh.grokCreditPct, 42)
        XCTAssertFalse(fresh.grokCreditStale)
        XCTAssertEqual(fresh.grokQuotaLabel, "WEEKLY")
        XCTAssertEqual(probe.interval, 240)
        XCTAssertEqual(probe.status, "usage_http_200 + ok")
        XCTAssertEqual(transport.requests[0].url, GrokBilling.billingURL)
        XCTAssertEqual(transport.requests[0].headers["Authorization"], "Bearer ccc.ready.sig")
        XCTAssertEqual(transport.requests[0].headers["x-xai-token-auth"], "xai-grok-cli")

        transport.queued = [.success(QuotaHTTPResponse(status: 500))]
        probe.refresh(monotonic: 1_300, wall: wall + 300)
        var stale = probe.grokFields(at: wall + 300)
        XCTAssertEqual(stale.grokCreditPct, 42)
        XCTAssertTrue(stale.grokCreditStale)
        XCTAssertEqual(probe.interval, 480)
        XCTAssertEqual(probe.status, "usage_request_failed")

        transport.queued = [.success(QuotaHTTPResponse(status: 502))]
        probe.refresh(monotonic: 1_800, wall: wall + 350)
        stale = probe.grokFields(at: wall + 350)
        XCTAssertEqual(stale.grokCreditPct, 42)
        XCTAssertTrue(stale.grokCreditStale)
        XCTAssertEqual(probe.interval, 960)

        transport.queued = [.success(QuotaHTTPResponse(status: 429, headers: ["Retry-After": "30"]))]
        probe.refresh(monotonic: 2_000, wall: wall + 400)
        XCTAssertEqual(probe.cooldownUntil, wall + 400 + 600)
        XCTAssertEqual(probe.grokFields(at: wall + 400).grokCreditPct, 42)
        XCTAssertTrue(probe.grokFields(at: wall + 400).grokCreditStale)
        XCTAssertTrue(probe.status.hasPrefix("usage_http_429"))
        let calls = transport.calls
        probe.refresh(monotonic: 2_100, wall: wall + 410)
        XCTAssertEqual(transport.calls, calls)
        XCTAssertEqual(probe.interval, 960)

        let passed = SubscriptionProbe(provider: .grok) { _ in
            SubscriptionSample(auth: "ready", status: "ok", reading: SubscriptionReading(pct: 90, resetAt: wall + 30, label: "WEEKLY"))
        }
        passed.refresh(monotonic: 1, wall: wall)
        let later = passed.grokFields(at: wall + 31)
        XCTAssertNil(later.grokCreditPct)
        XCTAssertFalse(later.grokCreditStale)

        let dropped = SubscriptionProbe(provider: .grok) { _ in
            SubscriptionSample(auth: "ready", status: "ok", reading: SubscriptionReading(pct: 42, resetAt: wall + 86_400, label: "WEEKLY"))
        }
        dropped.refresh(monotonic: 1, wall: wall)
        dropped.refresh(monotonic: 2, wall: wall)
        // second refresh replaces the closure's answer only if the closure changes; use a probe that switches.
        var answers = [
            SubscriptionSample(auth: "ready", status: "ok", reading: SubscriptionReading(pct: 42, resetAt: wall + 86_400, label: "WEEKLY")),
            SubscriptionSample(auth: "ready", status: "unmapped"),
        ]
        let switching = SubscriptionProbe(provider: .grok) { _ in answers.removeFirst() }
        switching.refresh(monotonic: 1, wall: wall)
        switching.refresh(monotonic: 2, wall: wall)
        XCTAssertNil(switching.grokFields(at: wall).grokCreditPct)
        XCTAssertNil(switching.grokFields(at: wall).grokQuotaLabel)
        XCTAssertEqual(switching.status, "usage_http_200 + no_mapped_limits")
        _ = dropped

        let quiet = ScriptedHTTP()
        quiet.error = URLError(.timedOut)
        let bare = SubscriptionProbe(provider: .grok) { now in
            SubscriptionFetch.grok(auth: auth, now: now, transport: quiet)
        }
        bare.refresh(monotonic: 1, wall: wall)
        XCTAssertNil(bare.grokFields(at: wall).grokCreditPct)
        XCTAssertFalse(bare.grokFields(at: wall).grokCreditStale)
        XCTAssertEqual(bare.status, "usage_request_failed")

        let local = ScriptedHTTP()
        var fetches = 0
        let missing = SubscriptionProbe(provider: .grok) { now in
            fetches += 1
            return SubscriptionFetch.grok(auth: GrokAuth(status: "missing"), now: now, transport: local)
        }
        XCTAssertEqual(missing.interval, 15)
        missing.kick(monotonic: 1_000, wall: wall)
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(local.calls, 0)
        XCTAssertEqual(missing.status, "no_grok_oauth_token")
        missing.kick(monotonic: 1_010, wall: wall + 10)
        XCTAssertEqual(fetches, 1)
        missing.kick(monotonic: 1_015, wall: wall + 15)
        XCTAssertEqual(fetches, 2)
        XCTAssertEqual(missing.interval, 15)

        let token = jwt(#"{"exp":1900000000,"sub":"auth0|user_01ABC"}"#)
        let cursorTransport = ScriptedHTTP()
        let summary = Data(#"{"billingCycleEnd":"1790726400","individualUsage":{"plan":{"totalPercentUsed":20,"autoPercentUsed":5,"apiPercentUsed":0}}}"#.utf8)
        cursorTransport.queued = [
            .success(QuotaHTTPResponse(status: 200, body: summary)),
            .success(QuotaHTTPResponse(status: 500)),
        ]
        let cursor = SubscriptionProbe(provider: .cursor) { now in
            SubscriptionFetch.cursor(status: "ready", token: token, now: now, transport: cursorTransport)
        }
        cursor.refresh(monotonic: 1_000, wall: wall)
        let bars = cursor.cursorFields(at: wall)
        XCTAssertEqual(bars.cursorTotalPct, 20)
        XCTAssertEqual(bars.cursorModelsPct, 5)
        XCTAssertEqual(bars.cursorThirdPct, 0)
        XCTAssertNil(bars.cursorBotPct)
        XCTAssertFalse(bars.cursorTotalStale)
        XCTAssertTrue(cursor.status.contains("sand_failed"))
        XCTAssertEqual(cursorTransport.requests[0].url, CursorUsage.usageURL)
        XCTAssertEqual(cursorTransport.requests[1].url, CursorUsage.sandURL)
        XCTAssertEqual(cursorTransport.requests[1].method, "POST")
        XCTAssertEqual(cursorTransport.requests[1].body, Data("{}".utf8))
        XCTAssertEqual(cursorTransport.requests[1].headers["Origin"], "https://cursor.com")
        XCTAssertEqual(cursor.interval, 240)

        let denied = ScriptedHTTP()
        denied.queued = [.success(QuotaHTTPResponse(status: 401))]
        let rejected = SubscriptionProbe(provider: .cursor) { now in
            SubscriptionFetch.cursor(status: "ready", token: token, now: now, transport: denied)
        }
        rejected.refresh(monotonic: 1, wall: wall)
        XCTAssertEqual(rejected.status, "token_dead_awaiting_refresh")
        XCTAssertEqual(rejected.auth, "unauthorized")
        XCTAssertEqual(rejected.interval, 15)
        XCTAssertEqual(denied.calls, 1)
        XCTAssertNil(rejected.cursorFields(at: wall).cursorTotalPct)

        let expiredTransport = ScriptedHTTP()
        let expired = SubscriptionProbe(provider: .cursor) { now in
            SubscriptionFetch.cursor(status: "expired", token: nil, now: now, transport: expiredTransport)
        }
        expired.refresh(monotonic: 1, wall: wall)
        XCTAssertEqual(expiredTransport.calls, 0)
        XCTAssertEqual(expired.status, "token_expired")
        XCTAssertEqual(expired.interval, 15)
    }

    func testTranscriptPriceCallbackSumsDollarsAndDefaultsToZero() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = localDate(year: 2026, month: 9, day: 15, hour: 12)
        let stamp = naiveStamp(now)
        let opus = usageLine(id: "m1", request: "r1", session: "s", timestamp: stamp, input: 10, model: "opus")
        let sonnet = usageLine(id: "m2", request: "r2", session: "s2", timestamp: stamp, input: 4, model: "sonnet")
        try write("a.jsonl", opus + sonnet, in: directory)
        try write("b.jsonl", opus, in: directory)

        let plain = TranscriptScanner().compute(projectsDirectory: directory, now: now)
        XCTAssertEqual(plain.monthTokens, 14)
        XCTAssertEqual(plain.monthUSD, 0)
        XCTAssertEqual(plain.unpricedTokens, 0)
        XCTAssertEqual(plain.pricedTokens, 14)

        let priced = TranscriptScanner().compute(projectsDirectory: directory, now: now) { model, usage in
            if model == "opus" { return (2.5, 0) }
            return (0, usage.total)
        }
        XCTAssertEqual(priced.monthUSD, 2.5)
        XCTAssertEqual(priced.pricedTokens, 10)
        XCTAssertEqual(priced.unpricedTokens, 4)
        XCTAssertEqual(priced.monthTokens, 14)
    }

    func testCodexProbeRestsOn429AndLeavesMissingViewFieldsNil() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = 1_700_000_000.0
        let sessions = directory.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let token = jwt(#"{"exp":1900000000,"sub":"acct"}"#)
        let authPath = try write("auth.json", """
        {"tokens":{"access_token":"\(token)","refresh_token":"refresh-secret","account_id":"acct"}}
        """, in: directory)
        let wham = try body([
            "rate_limit": [
                "primary_window": ["used_percent": 15, "limit_window_seconds": 18000, "reset_at": 1_900_000_000],
                "secondary_window": ["used_percent": 5, "limit_window_seconds": 604800, "reset_at": 1_900_100_000],
            ],
            "additional_rate_limits": [[
                "limit_name": "GPT-5.3-Codex-Spark",
                "primary_window": ["used_percent": 90, "limit_window_seconds": 604800, "reset_at": 1_900_200_000],
            ]],
        ])

        var cliCalls = 0
        let transport = ScriptedHTTP()
        let statePath = directory.appendingPathComponent("codex-probe-state.json")
        let probe = CodexProbe(
            transport: transport,
            lockPath: directory.appendingPathComponent("codex-probe.lock"),
            statePath: statePath,
            authPath: authPath,
            sessionsDirectory: sessions,
            appServer: { _ in
                cliCalls += 1
                var quota = CodexQuota()
                quota.codexWeekPct = 99
                return quota
            }
        )
        let before = probe.view(now: now, monotonic: 0)
        XCTAssertEqual(before.status, "not_run")
        XCTAssertEqual(before.streak, 0)
        XCTAssertEqual(before.interval, 240)
        XCTAssertNil(before.cooldownLeft)
        XCTAssertNil(before.age)
        XCTAssertEqual(transport.calls, 0)

        transport.queued = [.success(QuotaHTTPResponse(status: 200, body: wham))]
        let ok = probe.run(now: now, monotonic: 50)
        XCTAssertEqual(ok.limits, CodexOAuth.parseWhamUsage(wham, observedAt: 1_700_000_000, now: now))
        XCTAssertEqual(ok.view.status, "usage_http_200 + ok")
        XCTAssertEqual(ok.view.streak, 0)
        XCTAssertEqual(ok.view.interval, 240)
        XCTAssertNil(ok.view.cooldownLeft)
        XCTAssertEqual(ok.view.age, 0)
        XCTAssertEqual(probe.view(now: now, monotonic: 67).age, 17)
        XCTAssertEqual(cliCalls, 0)
        XCTAssertEqual(transport.calls, 1)
        XCTAssertEqual(transport.requests[0].url, CodexOAuth.defaultUsageURL)
        XCTAssertEqual(transport.requests[0].method, "GET")
        XCTAssertEqual(transport.requests[0].timeout, 15)
        XCTAssertNil(transport.requests[0].body)
        XCTAssertEqual(transport.requests[0].headers["Authorization"], "Bearer \(token)")
        XCTAssertEqual(transport.requests[0].headers["Accept"], "application/json")
        XCTAssertEqual(transport.requests[0].headers["User-Agent"], "vibepulse")
        XCTAssertEqual(transport.requests[0].headers["ChatGPT-Account-Id"], "acct")
        XCTAssertEqual(probe.authState, "ready")
        XCTAssertFalse(ok.view.status.contains(token))
        XCTAssertFalse(ok.view.status.contains("refresh-secret"))

        let zeroBody = try body([
            "rate_limit": [
                "primary_window": ["used_percent": 0, "limit_window_seconds": 18000, "reset_at": 1_900_000_000],
                "secondary_window": ["used_percent": 0, "limit_window_seconds": 604800, "reset_at": 1_900_100_000],
            ],
        ])
        transport.queued = [.success(QuotaHTTPResponse(status: 200, body: zeroBody))]
        let zeros = probe.run(now: now + 1, monotonic: 80)
        XCTAssertEqual(zeros.limits?.codexWeekPct, 0)
        XCTAssertEqual(zeros.limits?.codexSessionPct, 0)
        XCTAssertNil(zeros.view.cooldownLeft)

        transport.queued = [.success(QuotaHTTPResponse(status: 429, headers: ["Retry-After": "42"]))]
        let limited = probe.run(now: now + 2, monotonic: 90)
        XCTAssertNotNil(limited.limits)
        XCTAssertNil(limited.limits?.codexWeekPct)
        XCTAssertNil(limited.limits?.codexSessionPct)
        XCTAssertEqual(limited.view.status, "usage_http_429 + backoff_until_\(hhmm(now + 602))")
        XCTAssertEqual(probe.cooldownUntil, now + 602)
        XCTAssertEqual(limited.view.streak, 1)
        XCTAssertEqual(limited.view.interval, 480)
        XCTAssertEqual(limited.view.cooldownLeft, 600)
        XCTAssertEqual(cliCalls, 0)
        XCTAssertEqual(transport.calls, 3)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: statePath)) as? [String: Any]
        XCTAssertEqual((saved?["cooldown_until"] as? NSNumber)?.doubleValue, now + 602)
        let savedText = try String(contentsOf: statePath, encoding: .utf8)
        XCTAssertFalse(savedText.contains(token))
        XCTAssertFalse(savedText.contains("refresh-secret"))

        let resting = probe.run(now: now + 32, monotonic: 120)
        XCTAssertEqual(transport.calls, 3)
        XCTAssertEqual(cliCalls, 0)
        XCTAssertNil(resting.limits?.codexWeekPct)
        XCTAssertEqual(resting.view.status, limited.view.status)
        XCTAssertEqual(resting.view.streak, 2)
        XCTAssertEqual(resting.view.interval, 960)
        XCTAssertEqual(resting.view.cooldownLeft, 570)
        XCTAssertNil(probe.view(now: probe.cooldownUntil, monotonic: 120).cooldownLeft)

        let resumedNow = now + 602
        transport.queued = [.success(QuotaHTTPResponse(status: 200, body: wham))]
        let resumed = probe.run(now: resumedNow, monotonic: 800)
        XCTAssertEqual(resumed.limits, CodexOAuth.parseWhamUsage(wham, observedAt: 1_700_000_602, now: resumedNow))
        XCTAssertEqual(resumed.view.status, "usage_http_200 + ok")
        XCTAssertNil(resumed.view.cooldownLeft)
        XCTAssertEqual(resumed.view.streak, 0)
        XCTAssertEqual(probe.interval, 240)
        XCTAssertTrue(try String(contentsOf: statePath, encoding: .utf8).contains("cooldown_until"))

        transport.queued = [.failure(ProbeBoom())]
        let failed = probe.run(now: resumedNow + 1, monotonic: 810)
        XCTAssertEqual(failed.view.status, "usage_request_failed")
        XCTAssertNil(failed.limits?.codexWeekPct)
        XCTAssertEqual(probe.authState, "ready")
        XCTAssertEqual(probe.interval, 480)
        transport.queued = [.success(QuotaHTTPResponse(status: 500))]
        XCTAssertEqual(probe.run(now: resumedNow + 2, monotonic: 820).view.interval, 960)
        transport.queued = [.success(QuotaHTTPResponse(status: 302, headers: ["Location": "https://evil.example/usage"]))]
        let redirected = probe.run(now: resumedNow + 3, monotonic: 830)
        XCTAssertEqual(redirected.view.status, "usage_request_failed")
        XCTAssertEqual(transport.calls, 7)
        transport.queued = [.success(QuotaHTTPResponse(status: 200, body: Data("[]".utf8)))]
        XCTAssertEqual(probe.run(now: resumedNow + 4, monotonic: 840).view.status, "usage_http_200 + no_mapped_limits")
        transport.queued = [.success(QuotaHTTPResponse(status: 200, body: Data("not-json".utf8)))]
        XCTAssertEqual(probe.run(now: resumedNow + 5, monotonic: 850).view.status, "usage_request_failed")
        XCTAssertEqual(cliCalls, 0)
        XCTAssertEqual(probe.interval, 960)

        let longTransport = ScriptedHTTP()
        let long = CodexProbe(
            transport: longTransport,
            lockPath: directory.appendingPathComponent("long.lock"),
            statePath: directory.appendingPathComponent("long.json"),
            authPath: authPath,
            sessionsDirectory: sessions
        )
        longTransport.queued = [.success(QuotaHTTPResponse(status: 429, headers: ["Retry-After": "900"]))]
        XCTAssertEqual(long.run(now: now, monotonic: 1).view.cooldownLeft, 900)
        XCTAssertEqual(long.cooldownUntil, now + 900)
        let datedTransport = ScriptedHTTP()
        let dated = CodexProbe(
            transport: datedTransport,
            lockPath: directory.appendingPathComponent("date.lock"),
            statePath: directory.appendingPathComponent("date.json"),
            authPath: authPath,
            sessionsDirectory: sessions
        )
        let until = now + 1_000
        datedTransport.queued = [.success(QuotaHTTPResponse(status: 429, headers: ["Retry-After": httpDate(until)]))]
        let datedRun = dated.run(now: now, monotonic: 1)
        XCTAssertEqual(dated.cooldownUntil, until)
        XCTAssertEqual(datedRun.view.cooldownLeft, 1_000)

        let persistedUntil = now + 50_000
        let coldState = try write("cold/state.json", #"{"cooldown_until": \#(persistedUntil)}"#, in: directory)
        let coldLock = directory.appendingPathComponent("cold/lock")
        let coldTransport = ScriptedHTTP()
        let cold = CodexProbe(transport: coldTransport, lockPath: coldLock, statePath: coldState, authPath: authPath, sessionsDirectory: sessions)
        let coldResult = cold.run(now: now, monotonic: 10)
        XCTAssertEqual(coldTransport.calls, 0)
        XCTAssertNil(coldResult.limits)
        XCTAssertEqual(coldResult.view.status, "usage_http_429 + backoff_until_\(hhmm(persistedUntil)) (persisted)")
        XCTAssertEqual(coldResult.view.streak, 1)
        XCTAssertEqual(coldResult.view.cooldownLeft, 50_000)
        XCTAssertEqual(coldResult.view.age, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: coldLock.path))

        let staleState = try write("stale/state.json", #"{"cooldown_until": \#(now - 5)}"#, in: directory)
        let staleTransport = ScriptedHTTP()
        staleTransport.queued = [.success(QuotaHTTPResponse(status: 200, body: wham))]
        let stale = CodexProbe(
            transport: staleTransport,
            lockPath: directory.appendingPathComponent("stale/lock"),
            statePath: staleState,
            authPath: authPath,
            sessionsDirectory: sessions
        )
        let staleRun = stale.run(now: now, monotonic: 1)
        XCTAssertEqual(staleTransport.calls, 1)
        XCTAssertEqual(staleRun.view.status, "usage_http_200 + ok")
        let garbageState = try write("garbage/state.json", "not json", in: directory)
        let garbageTransport = ScriptedHTTP()
        garbageTransport.queued = [.success(QuotaHTTPResponse(status: 200, body: wham))]
        let garbage = CodexProbe(
            transport: garbageTransport,
            lockPath: directory.appendingPathComponent("garbage/lock"),
            statePath: garbageState,
            authPath: authPath,
            sessionsDirectory: sessions
        )
        XCTAssertEqual(garbage.run(now: now, monotonic: 1).view.status, "usage_http_200 + ok")

        let heldTransport = ScriptedHTTP()
        let heldLock = directory.appendingPathComponent("held.lock")
        let holder = ProbeFileLock.acquire(heldLock)
        let held = CodexProbe(
            transport: heldTransport,
            lockPath: heldLock,
            statePath: directory.appendingPathComponent("held.json"),
            authPath: authPath,
            sessionsDirectory: sessions
        )
        heldTransport.queued = [.success(QuotaHTTPResponse(status: 200, body: wham))]
        let blocked = held.run(now: now, monotonic: 1)
        XCTAssertEqual(blocked.view.status, "probe_held_by_other_instance")
        XCTAssertNil(blocked.limits)
        XCTAssertEqual(blocked.view.streak, 1)
        XCTAssertEqual(held.authState, "unknown")
        XCTAssertEqual(held.interval, 480)
        XCTAssertEqual(heldTransport.calls, 0)
        holder?.release()
        let released = held.run(now: now, monotonic: 2)
        XCTAssertEqual(released.view.status, "usage_http_200 + ok")
        XCTAssertEqual(heldTransport.calls, 1)
        let again = ProbeFileLock.acquire(heldLock)
        let kept = held.run(now: now, monotonic: 3)
        XCTAssertEqual(kept.limits?.codexWeekPct, 5)
        XCTAssertEqual(kept.view.status, "probe_held_by_other_instance")
        XCTAssertEqual(heldTransport.calls, 1)
        again?.release()

        let customAuth = try write("custom/auth.json", #"{"tokens":{"access_token":"\#(token)"}}"#, in: directory)
        try write("custom/config.toml", "chatgpt_base_url = \"https://example.com\"\n", in: directory)
        let customTransport = ScriptedHTTP()
        customTransport.queued = [.success(QuotaHTTPResponse(status: 200, body: wham))]
        let custom = CodexProbe(
            transport: customTransport,
            lockPath: directory.appendingPathComponent("custom/lock"),
            statePath: directory.appendingPathComponent("custom/state.json"),
            authPath: customAuth,
            sessionsDirectory: sessions
        )
        _ = custom.run(now: now, monotonic: 1)
        XCTAssertEqual(customTransport.requests[0].url, "https://example.com/api/codex/usage")
        XCTAssertNil(customTransport.requests[0].headers["ChatGPT-Account-Id"])

        let badAuth = try write("bad/auth.json", #"{"tokens":{"access_token":"\#(token)","account_id":"acct"}}"#, in: directory)
        try write("bad/config.toml", "chatgpt_base_url = \"http://chatgpt.com/backend-api\"\n", in: directory)
        var badCLI = 0
        let badTransport = ScriptedHTTP()
        let bad = CodexProbe(
            transport: badTransport,
            lockPath: directory.appendingPathComponent("bad/lock"),
            statePath: directory.appendingPathComponent("bad/state.json"),
            authPath: badAuth,
            sessionsDirectory: sessions,
            appServer: { _ in
                badCLI += 1
                return CodexQuota()
            }
        )
        let rejectedURL = bad.run(now: now, monotonic: 1)
        XCTAssertEqual(badTransport.calls, 0)
        XCTAssertEqual(badCLI, 0)
        XCTAssertEqual(rejectedURL.view.status, "usage_request_failed")
        XCTAssertEqual(bad.authState, "ready")
        XCTAssertNil(rejectedURL.limits?.codexWeekPct)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("bad/lock").path))
    }

    func testCodexProbeFallsBackToTheCLIWhenTheCredentialCannotBeUsed() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = 1_800_000_000.0
        let sessions = directory.appendingPathComponent("sessions", isDirectory: true)
        let line = #"{"timestamp":"2026-08-07T10:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"tail","primary":{"used_percent":35,"window_minutes":10080,"resets_at":1900000000}}}}"# + "\n"
        try write("rollout-a.jsonl", line, in: sessions)
        let authPath = directory.appendingPathComponent("auth.json")

        var appCalls = 0
        var appQuota = CodexQuota()
        appQuota.codexWeekPct = 62
        var appThrows = false
        let transport = ScriptedHTTP()
        let probe = CodexProbe(
            transport: transport,
            lockPath: directory.appendingPathComponent("lock"),
            statePath: directory.appendingPathComponent("state.json"),
            authPath: authPath,
            sessionsDirectory: sessions,
            appServer: { _ in
                appCalls += 1
                if appThrows { throw ProbeBoom() }
                return appQuota
            }
        )
        let first = probe.run(now: now, monotonic: 1_000)
        XCTAssertEqual(transport.calls, 0)
        XCTAssertEqual(appCalls, 1)
        XCTAssertEqual(first.limits?.codexWeekPct, 62)
        XCTAssertEqual(first.view.status, "cli")
        XCTAssertEqual(first.view.streak, 0)
        XCTAssertEqual(probe.authState, "missing")
        XCTAssertEqual(probe.interval, 15)
        XCTAssertNil(first.view.cooldownLeft)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("lock").path))

        appQuota.codexWeekPct = 10
        let quiet = probe.run(now: now, monotonic: 1_015)
        XCTAssertEqual(appCalls, 1)
        XCTAssertEqual(quiet.limits?.codexWeekPct, 62)
        XCTAssertEqual(quiet.view.status, "cli")
        XCTAssertEqual(quiet.view.streak, 0)

        let again = probe.run(now: now, monotonic: 1_240)
        XCTAssertEqual(appCalls, 2)
        XCTAssertEqual(again.limits?.codexWeekPct, 10)

        appQuota = CodexQuota()
        let scanned = probe.run(now: now, monotonic: 1_480)
        XCTAssertEqual(appCalls, 3)
        XCTAssertEqual(scanned.limits?.codexWeekPct, 35)
        XCTAssertEqual(scanned.view.status, "cli")
        XCTAssertEqual(probe.interval, 15)

        try FileManager.default.removeItem(at: sessions.appendingPathComponent("rollout-a.jsonl"))
        let sessionOnly = #"{"timestamp":"2026-08-07T10:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":15,"window_minutes":300,"resets_at":1900000000}}}}"# + "\n"
        try write("rollout-session.jsonl", sessionOnly, in: sessions)
        let session = probe.run(now: now, monotonic: 1_720)
        XCTAssertEqual(session.view.status, "cli")
        XCTAssertNil(session.limits?.codexWeekPct)
        XCTAssertEqual(session.limits?.codexSessionPct, 15)

        try FileManager.default.removeItem(at: sessions.appendingPathComponent("rollout-session.jsonl"))
        let empty = probe.run(now: now, monotonic: 1_960)
        XCTAssertEqual(empty.view.status, "no_codex_oauth_token; cli_empty")
        XCTAssertNil(empty.limits?.codexWeekPct)
        XCTAssertNil(empty.limits?.codexSessionPct)
        XCTAssertEqual(empty.view.streak, 1)
        XCTAssertEqual(probe.interval, 15)
        let skipped = probe.run(now: now, monotonic: 1_960 + 479)
        XCTAssertEqual(appCalls, 5)
        XCTAssertEqual(skipped.view.status, "no_codex_oauth_token; cli_empty")
        XCTAssertEqual(skipped.view.streak, 1)
        let secondEmpty = probe.run(now: now, monotonic: 1_960 + 480)
        XCTAssertEqual(appCalls, 6)
        XCTAssertEqual(secondEmpty.view.streak, 2)
        let stillWaiting = probe.run(now: now, monotonic: 1_960 + 480 + 959)
        XCTAssertEqual(appCalls, 6)
        XCTAssertEqual(stillWaiting.view.streak, 2)
        XCTAssertEqual(probe.run(now: now, monotonic: 1_960 + 480 + 960).view.streak, 3)

        appQuota.codexWeekPct = 62
        appThrows = false
        _ = probe.run(now: now, monotonic: 1_960 + 480 + 960 + 960)
        let callsBeforeCrash = appCalls
        appThrows = true
        let crashed = probe.run(now: now, monotonic: 1_960 + 480 + 960 + 960 + 240)
        XCTAssertEqual(appCalls, callsBeforeCrash + 1)
        XCTAssertEqual(crashed.view.status, "probe_crashed: ProbeBoom")
        XCTAssertNil(crashed.limits?.codexWeekPct)
        XCTAssertEqual(probe.authState, "missing")
        XCTAssertEqual(probe.interval, 15)

        let expiredToken = jwt(#"{"exp":1800000000}"#)
        let expiredAuth = try write("expired/auth.json", #"{"tokens":{"access_token":"\#(expiredToken)","refresh_token":"refresh-secret"}}"#, in: directory)
        let expiredTransport = ScriptedHTTP()
        let expired = CodexProbe(
            transport: expiredTransport,
            lockPath: directory.appendingPathComponent("expired/lock"),
            statePath: directory.appendingPathComponent("expired/state.json"),
            authPath: expiredAuth,
            sessionsDirectory: directory.appendingPathComponent("no-sessions", isDirectory: true)
        )
        let expiredRun = expired.run(now: now, monotonic: 5)
        XCTAssertEqual(expiredTransport.calls, 0)
        XCTAssertEqual(expiredRun.view.status, "token_expired; cli_empty")
        XCTAssertEqual(expired.authState, "expired")
        XCTAssertEqual(expired.interval, 15)
        XCTAssertNil(expiredRun.limits?.codexWeekPct)
        XCTAssertFalse(expiredRun.view.status.contains(expiredToken))

        let wham = try body([
            "rate_limit": [
                "primary_window": ["used_percent": 15, "limit_window_seconds": 18000, "reset_at": 1_900_000_000],
                "secondary_window": ["used_percent": 5, "limit_window_seconds": 604800, "reset_at": 1_900_100_000],
            ],
        ])
        var forced = 0
        let deadTransport = ScriptedHTTP()
        let deadAuth = directory.appendingPathComponent("dead-auth.json")
        let deadProbe = CodexProbe(
            transport: deadTransport,
            lockPath: directory.appendingPathComponent("dead.lock"),
            statePath: directory.appendingPathComponent("dead.json"),
            authPath: deadAuth,
            sessionsDirectory: directory.appendingPathComponent("empty-sessions", isDirectory: true),
            appServer: { _ in
                forced += 1
                var quota = CodexQuota()
                quota.codexWeekPct = 62
                return quota
            }
        )
        let missing = deadProbe.run(now: now, monotonic: 3_000)
        XCTAssertEqual(missing.view.status, "cli")
        XCTAssertEqual(forced, 1)
        let live = jwt(#"{"exp":1900000000,"n":1}"#)
        try write("dead-auth.json", #"{"tokens":{"access_token":"\#(live)","account_id":"acct"}}"#, in: directory)
        deadTransport.queued = [.success(QuotaHTTPResponse(status: 401))]
        let rejected = deadProbe.run(now: now, monotonic: 3_010)
        XCTAssertEqual(deadTransport.calls, 1)
        XCTAssertEqual(forced, 2)
        XCTAssertTrue(deadProbe.isDead(live))
        XCTAssertEqual(rejected.view.status, "cli")
        XCTAssertEqual(rejected.limits?.codexWeekPct, 62)
        XCTAssertEqual(deadProbe.authState, "unauthorized")
        XCTAssertEqual(deadProbe.interval, 15)
        let parked = deadProbe.run(now: now, monotonic: 3_020)
        XCTAssertEqual(deadTransport.calls, 1)
        XCTAssertEqual(forced, 2)
        XCTAssertEqual(parked.limits?.codexWeekPct, 62)
        XCTAssertEqual(parked.view.status, "cli")
        XCTAssertEqual(parked.view.streak, 0)

        let fresh = jwt(#"{"exp":1900000000,"n":2}"#)
        try write("dead-auth.json", #"{"tokens":{"access_token":"\#(fresh)","account_id":"acct"}}"#, in: directory)
        deadTransport.queued = [.success(QuotaHTTPResponse(status: 200, body: wham))]
        let recovered = deadProbe.run(now: now, monotonic: 3_030)
        XCTAssertEqual(recovered.view.status, "usage_http_200 + ok")
        XCTAssertEqual(recovered.limits?.codexWeekPct, 5)
        XCTAssertEqual(forced, 2)
        XCTAssertEqual(deadProbe.interval, 240)
        XCTAssertEqual(deadProbe.authState, "ready")
        XCTAssertTrue(deadProbe.isDead(live))
        XCTAssertFalse(deadProbe.isDead(fresh))

        var tokens: [String] = []
        let fifoTransport = ScriptedHTTP()
        let fifoAuth = directory.appendingPathComponent("fifo.json")
        let fifo = CodexProbe(
            transport: fifoTransport,
            lockPath: directory.appendingPathComponent("fifo.lock"),
            statePath: directory.appendingPathComponent("fifo-state.json"),
            authPath: fifoAuth,
            sessionsDirectory: directory.appendingPathComponent("fifo-sessions", isDirectory: true),
            appServer: { _ in CodexQuota() }
        )
        for index in 0..<9 {
            let access = jwt("{\"exp\":1900000000,\"n\":\(index)}")
            tokens.append(access)
            try write("fifo.json", #"{"tokens":{"access_token":"\#(access)"}}"#, in: directory)
            fifoTransport.queued = [.success(QuotaHTTPResponse(status: index == 3 ? 403 : 401))]
            _ = fifo.run(now: now, monotonic: 20_000 + Double(index))
        }
        XCTAssertEqual(fifoTransport.calls, 9)
        XCTAssertEqual(fifo.deadTokenCount, 8)
        XCTAssertFalse(fifo.isDead(tokens[0]))
        XCTAssertTrue(fifo.isDead(tokens[1]))
        XCTAssertTrue(fifo.isDead(tokens[8]))
        let after = fifoTransport.calls
        _ = fifo.run(now: now, monotonic: 20_050)
        XCTAssertEqual(fifoTransport.calls, after)
        try write("fifo.json", #"{"tokens":{"access_token":"\#(tokens[0])"}}"#, in: directory)
        fifoTransport.queued = [.success(QuotaHTTPResponse(status: 401))]
        _ = fifo.run(now: now, monotonic: 20_051)
        XCTAssertEqual(fifoTransport.calls, after + 1)
        XCTAssertEqual(fifoTransport.requests.last?.headers["Authorization"], "Bearer \(tokens[0])")
        XCTAssertTrue(fifo.isDead(tokens[0]))
        XCTAssertEqual(fifo.interval, 15)
    }

    private func limitHeaders(modelBucket: String) -> [String: String] {
        [
            "anthropic-ratelimit-unified-5h-utilization": "0.12",
            "anthropic-ratelimit-unified-5h-reset": "3600",
            "anthropic-ratelimit-unified-7d-utilization": "0.47",
            "anthropic-ratelimit-unified-7d-reset": "7200",
            "anthropic-ratelimit-unified-\(modelBucket)-utilization": "0.73",
            "anthropic-ratelimit-unified-\(modelBucket)-reset": "10800",
        ]
    }

    private func body(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func jwt(_ payload: String) -> String {
        let encoded = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(encoded).sig"
    }

    private func utf16LE(_ text: String) -> Data {
        var data = Data(capacity: text.utf16.count * 2)
        for unit in text.utf16 {
            data.append(UInt8(unit & 0xFF))
            data.append(UInt8((unit >> 8) & 0xFF))
        }
        return data
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vibepulse-providers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func localDate(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0) -> Date {
        let calendar = Calendar.current
        var parts = DateComponents()
        parts.calendar = calendar
        parts.timeZone = calendar.timeZone
        parts.year = year
        parts.month = month
        parts.day = day
        parts.hour = hour
        parts.minute = minute
        parts.second = second
        return calendar.date(from: parts)!
    }

    private func naiveStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: date)
    }

    private func zulu(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func usageLine(id: String, request: String?, session: String?, timestamp: String, input: Int = 0, output: Int = 0, cacheCreate: Int = 0, cacheRead: Int = 0, model: String? = nil) -> String {
        var line = "{"
        if let session { line += "\"sessionId\":\"\(session)\"," }
        if let request { line += "\"requestId\":\"\(request)\"," }
        line += "\"timestamp\":\"\(timestamp)\","
        line += "\"message\":{\"id\":\"\(id)\","
        if let model { line += "\"model\":\"\(model)\"," }
        line += "\"usage\":{"
        line += "\"input_tokens\":\(input),\"output_tokens\":\(output),"
        line += "\"cache_creation_input_tokens\":\(cacheCreate),\"cache_read_input_tokens\":\(cacheRead)}}}\n"
        return line
    }

    private func hhmm(_ epoch: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: epoch))
    }

    private func httpDate(_ epoch: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.string(from: Date(timeIntervalSince1970: epoch))
    }

    private func codexTurn(_ model: String) -> String {
        #"{"type":"turn_context","payload":{"model":"\#(model)"}}"# + "\n"
    }

    private func codexMeta(_ session: String) -> String {
        #"{"type":"session_meta","payload":{"id":"file","session_id":"\#(session)"}}"# + "\n"
    }

    private func codexToken(input: Int, total: Int = 0, stamp: String) -> String {
        #"{"timestamp":"\#(stamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\#(input),"output_tokens":0,"cache_write_input_tokens":0},"total_token_usage":{"input_tokens":\#(total)}}}}"# + "\n"
    }

    @discardableResult
    private func write(_ relative: String, _ text: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: false, encoding: .utf8)
        return url
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
    }
}

private final class ScriptedHTTP: QuotaHTTPTransport {
    var response = QuotaHTTPResponse(status: 200)
    var error: Error?
    var queued: [Result<QuotaHTTPResponse, Error>] = []
    private(set) var calls = 0
    private(set) var requests: [QuotaHTTPRequest] = []
    private(set) var last: QuotaHTTPRequest?
    func send(_ request: QuotaHTTPRequest) throws -> QuotaHTTPResponse {
        calls += 1
        requests.append(request)
        last = request
        if !queued.isEmpty { return try queued.removeFirst().get() }
        if let error { throw error }
        return response
    }
}

private struct ProbeBoom: Error {}

private struct ListedProcesses: ProcessInspecting {
    var ids: [String] = []
    var lines: [String: String] = [:]
    func processIDs(matching pattern: String) -> [String] { ids }
    func commandLine(pid: String) -> String? { lines[pid] }
}

private struct MemoryCursor: CursorStateReading {
    var blob: Data?
    func value(forKey key: String, inDatabase path: String) -> Data? {
        key == CursorUsage.tokenKey ? blob : nil
    }
}
