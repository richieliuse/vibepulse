import Foundation

public struct ClaudeProbeResult: Equatable {
    public var limits: ClaudeUsageLimits?
    public var status: String
    public var failureStreak: Int
    public var cooldownUntil: TimeInterval
    public var interval: TimeInterval
    public var credential: ClaudeCredentialSnapshot
    public var ratelimitHeaders: [String]
    public var unknownBuckets: [String]

    public init(limits: ClaudeUsageLimits?, status: String, failureStreak: Int, cooldownUntil: TimeInterval, interval: TimeInterval, credential: ClaudeCredentialSnapshot, ratelimitHeaders: [String], unknownBuckets: [String]) {
        self.limits = limits
        self.status = status
        self.failureStreak = failureStreak
        self.cooldownUntil = cooldownUntil
        self.interval = interval
        self.credential = credential
        self.ratelimitHeaders = ratelimitHeaders
        self.unknownBuckets = unknownBuckets
    }
}

/// One Claude usage cycle. Candidates, HTTP, and the clock are injected.
/// A future `cooldown_until` makes no request. 401/403 values stay dead (FIFO of 8).
public final class ClaudeProbe {
    public static let deadTokenCapacity = 8
    public static let rateLimitFloor: TimeInterval = 600
    public static let limitsEvery: TimeInterval = 240
    public static let authRecoveryEvery: TimeInterval = 15
    public static let bridgedEvery: TimeInterval = 1800
    public static let messagesURL = "https://api.anthropic.com/v1/messages"

    public var statuslineBridged = false
    public private(set) var status = "not_run"
    public private(set) var failureStreak = 0
    public private(set) var cooldownUntil: TimeInterval = 0
    public private(set) var credential = ClaudeCredentialSnapshot(status: "unknown")
    public private(set) var ratelimitHeaders: [String] = []
    public private(set) var unknownBuckets: [String] = []
    public private(set) var limits: ClaudeUsageLimits?

    private let transport: any QuotaHTTPTransport
    private let lockPath: URL
    private let statePath: URL
    private var stateLoaded = false
    private var deadOrder: [String] = []
    private var deadReason: [String: String] = [:]
    private var lastProbed: TimeInterval = 0

    public init(transport: any QuotaHTTPTransport, lockPath: URL, statePath: URL) {
        self.transport = transport
        self.lockPath = lockPath
        self.statePath = statePath
    }

    public var deadTokenCount: Int { deadOrder.count }

    public func isDead(_ token: String) -> Bool { deadReason[token] != nil }

    public var interval: TimeInterval {
        if status.hasPrefix("no_claude_oauth_token")
            || status.hasPrefix("token_expired_")
            || status.hasPrefix("token_dead_awaiting_refresh") {
            return Self.authRecoveryEvery
        }
        if statuslineBridged && status == "usage_http_200 + ok" {
            return Self.bridgedEvery
        }
        let shift = min(max(failureStreak, 0), 2)
        return Self.limitsEvery * TimeInterval(1 << shift)
    }

    public func age(at monotonic: TimeInterval) -> Int? {
        guard lastProbed != 0 else { return nil }
        return Int((monotonic - lastProbed).rounded(.towardZero))
    }

    public func cooldownLeft(at now: TimeInterval) -> Int? {
        let left = cooldownUntil - now
        guard left > 0 else { return nil }
        return Int(ceil(left))
    }

    /// One cycle. `keychainReason` is appended only when `candidates` is empty.
    public func run(candidates: [ClaudeOAuthCandidate], keychainReason: String? = nil, now: TimeInterval, monotonic: TimeInterval) -> ClaudeProbeResult {
        loadStateIfNeeded(now: now)
        if now < cooldownUntil {
            failureStreak += 1
            lastProbed = monotonic
            limits = nil
            return snapshot(limits: nil)
        }
        guard let lock = ProbeFileLock.acquire(lockPath) else {
            status = "probe_held_by_other_instance"
            ratelimitHeaders = []
            unknownBuckets = []
            failureStreak += 1
            lastProbed = monotonic
            limits = nil
            return snapshot(limits: nil)
        }
        defer { lock.release() }
        let found = cycle(candidates: candidates, keychainReason: keychainReason, now: now)
        failureStreak = found == nil ? failureStreak + 1 : 0
        lastProbed = monotonic
        limits = found
        return snapshot(limits: found)
    }

    private func loadStateIfNeeded(now: TimeInterval) {
        guard !stateLoaded else { return }
        stateLoaded = true
        guard let until = ProbeCooldownFile.load(statePath), until.isFinite, until > now else { return }
        cooldownUntil = until
        status = "usage_http_429 + backoff_until_\(ProbeClock.hhmm(until)) (persisted)"
    }

    private func cycle(candidates: [ClaudeOAuthCandidate], keychainReason: String?, now: TimeInterval) -> ClaudeUsageLimits? {
        var outcome = Outcome(status: status)
        outcome.credential = ClaudeOAuthCandidates.credentialSnapshot(candidates, now: now)
        if candidates.isEmpty {
            outcome.status = "no_claude_oauth_token"
            if let keychainReason, !keychainReason.isEmpty {
                outcome.status += ": \(keychainReason)"
                outcome.credential.reason = keychainReason
            }
            publish(outcome)
            return nil
        }

        var token: String?
        for candidate in candidates {
            if deadReason[candidate.token] != nil {
                outcome.status = "token_dead_awaiting_refresh"
                continue
            }
            if let expires = candidate.expiresAtMilliseconds, expires.isFinite, expires != 0, expires / 1000 < now {
                outcome.status = "token_expired_\(ProbeClock.hhmm(expires / 1000))"
                continue
            }
            let request = QuotaHTTPRequest(
                url: ClaudeLimits.usageURL,
                method: "GET",
                headers: [
                    "Authorization": "Bearer \(candidate.token)",
                    "anthropic-beta": "oauth-2025-04-20",
                    "User-Agent": "claude-cli/2.1.227 (external, cli)",
                ],
                timeout: 15
            )
            let response: QuotaHTTPResponse
            do {
                response = try transport.send(request)
            } catch {
                outcome.status = "usage_request_failed: \(String(describing: type(of: error)))"
                token = candidate.token
                break
            }
            if !(200..<300).contains(response.status) {
                outcome.status = "usage_http_\(response.status)"
                if response.status == 429 {
                    let parsed = RetryAfter.integer(response.header("Retry-After") ?? "") ?? 0
                    let until = now + Double(max(parsed, Int(Self.rateLimitFloor)))
                    outcome.cooldownUntil = until
                    outcome.status = "usage_http_429 + backoff_until_\(ProbeClock.hhmm(until))"
                    cooldownUntil = until
                    ProbeCooldownFile.save(until, to: statePath)
                    publish(outcome)
                    return nil
                }
                if response.status == 401 || response.status == 403 {
                    rememberDead(candidate.token, code: response.status)
                    continue
                }
                token = candidate.token
                break
            }
            let found = ClaudeLimits.parseUsageLimits(response.body, now: now)
            if hasMapped(found) {
                outcome.status = "usage_http_200 + ok"
                publish(outcome)
                return found
            }
            outcome.status = "usage_http_200 + no_mapped_limits"
            token = candidate.token
            break
        }

        guard let token else {
            publish(outcome)
            return nil
        }
        return headerFallback(token: token, outcome: &outcome, now: now)
    }

    private func headerFallback(token: String, outcome: inout Outcome, now: TimeInterval) -> ClaudeUsageLimits? {
        let body = Data(#"{"model": "claude-haiku-4-5", "max_tokens": 0, "messages": [{"role": "user", "content": "ping"}]}"#.utf8)
        let request = QuotaHTTPRequest(
            url: Self.messagesURL,
            method: "POST",
            headers: [
                "Content-Type": "application/json",
                "Authorization": "Bearer \(token)",
                "anthropic-version": "2023-06-01",
                "anthropic-beta": "oauth-2025-04-20",
            ],
            body: body,
            timeout: 15
        )
        let response: QuotaHTTPResponse
        do {
            response = try transport.send(request)
        } catch {
            outcome.status += "; fallback_failed: \(String(describing: type(of: error)))"
            publish(outcome)
            return nil
        }
        outcome.status += "; fallback_http_\(response.status)"
        let found = ClaudeLimits.parseLimitHeaders(response.headers, now: now)
        outcome.headers = response.headers.keys.filter { $0.lowercased().contains("ratelimit") }.sorted()
        outcome.unknownBuckets = found.unknownBuckets
        if !hasMapped(found) {
            outcome.status += " + no_mapped_headers"
            publish(outcome)
            return nil
        }
        outcome.status += " + ok"
        publish(outcome)
        return found
    }

    private func rememberDead(_ token: String, code: Int) {
        if deadReason[token] == nil {
            deadOrder.append(token)
        }
        deadReason[token] = "http_\(code)"
        while deadOrder.count > Self.deadTokenCapacity {
            let oldest = deadOrder.removeFirst()
            deadReason.removeValue(forKey: oldest)
        }
    }

    private func publish(_ outcome: Outcome) {
        status = outcome.status
        ratelimitHeaders = outcome.headers
        unknownBuckets = outcome.unknownBuckets
        credential = outcome.credential
        if let until = outcome.cooldownUntil {
            cooldownUntil = until
        }
    }

    private func snapshot(limits: ClaudeUsageLimits?) -> ClaudeProbeResult {
        ClaudeProbeResult(
            limits: limits,
            status: status,
            failureStreak: failureStreak,
            cooldownUntil: cooldownUntil,
            interval: interval,
            credential: credential,
            ratelimitHeaders: ratelimitHeaders,
            unknownBuckets: unknownBuckets
        )
    }

    private func hasMapped(_ limits: ClaudeUsageLimits) -> Bool {
        limits.sessionPct != nil || limits.sessionResetAt != nil
            || limits.weekPct != nil || limits.weekResetAt != nil
            || limits.modelPct != nil || limits.modelResetAt != nil
            || limits.modelLabel != nil
    }

    private struct Outcome {
        var status: String
        var headers: [String] = []
        var unknownBuckets: [String] = []
        var credential = ClaudeCredentialSnapshot(status: "unknown")
        var cooldownUntil: TimeInterval?
    }
}
