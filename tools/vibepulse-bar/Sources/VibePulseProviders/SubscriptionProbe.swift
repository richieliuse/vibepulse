import Foundation

public struct SubscriptionReading: Equatable {
    public var pct: Double?
    public var resetAt: TimeInterval?
    public var label: String?

    public init(pct: Double? = nil, resetAt: TimeInterval? = nil, label: String? = nil) {
        self.pct = pct
        self.resetAt = resetAt
        self.label = label
    }
}

/// One Cursor or Grok fetch, with no token retained.
public struct SubscriptionSample {
    public var auth: String
    public var status: String?
    public var summary: String?
    public var sand: String?
    public var retryAfter: Int
    public var reading: SubscriptionReading?
    public var total: SubscriptionReading?
    public var models: SubscriptionReading?
    public var third: SubscriptionReading?
    public var bot: SubscriptionReading?

    public init(auth: String, status: String? = nil, summary: String? = nil, sand: String? = nil, retryAfter: Int = 0, reading: SubscriptionReading? = nil, total: SubscriptionReading? = nil, models: SubscriptionReading? = nil, third: SubscriptionReading? = nil, bot: SubscriptionReading? = nil) {
        self.auth = auth
        self.status = status
        self.summary = summary
        self.sand = sand
        self.retryAfter = retryAfter
        self.reading = reading
        self.total = total
        self.models = models
        self.third = third
        self.bot = bot
    }
}

public struct SubscriptionDiagnostics: Equatable {
    public var status: String
    public var interval: Int
    public var cooldownLeft: Int?
    public var age: Int?

    public init(status: String, interval: Int, cooldownLeft: Int?, age: Int?) {
        self.status = status
        self.interval = interval
        self.cooldownLeft = cooldownLeft
        self.age = age
    }
}

/// Cursor and Grok cadence. Success waits 240 s, then 480 s, then 960 s.
/// Missing, expired, and rejected credentials are re-read every 15 s.
/// HTTP 429 rests at least 10 minutes. A transport failure marks a saved
/// percent stale and does not replace it with zero.
public final class SubscriptionProbe {
    public enum Provider: String {
        case grok
        case cursor
    }

    public static let limitsEvery: TimeInterval = 240
    public static let authRecoveryEvery: TimeInterval = 15
    public static let rateLimitFloor: TimeInterval = 600

    public let provider: Provider
    public private(set) var refreshing = false
    public private(set) var failureStreak = 0
    public private(set) var cooldownUntil: TimeInterval = 0
    public private(set) var auth = "missing"
    public private(set) var status = "idle"

    private let fetch: (TimeInterval) throws -> SubscriptionSample
    private var lastMono: TimeInterval = 0
    private var lanes: [String: Lane] = [:]
    private var label: String?

    public init(provider: Provider, fetch: @escaping (TimeInterval) throws -> SubscriptionSample) {
        self.provider = provider
        self.fetch = fetch
    }

    public var interval: TimeInterval {
        if auth == "missing" || auth == "expired" || auth == "unauthorized" {
            return Self.authRecoveryEvery
        }
        let shift = min(max(failureStreak, 0), 2)
        return Self.limitsEvery * TimeInterval(1 << shift)
    }

    /// Runs even when the cadence interval has not elapsed. A cooldown skips the fetch.
    public func refresh(monotonic: TimeInterval, wall: TimeInterval) {
        if wall < cooldownUntil {
            failureStreak += 1
            lastMono = monotonic
            refreshing = false
            return
        }
        let raw = sample(at: wall)
        note(raw, wall: wall)
        lastMono = monotonic
        refreshing = false
    }

    /// Due check, then one fetch. `lastMono == 0` means this probe has never run.
    public func kick(monotonic: TimeInterval, wall: TimeInterval) {
        if refreshing { return }
        if lastMono != 0, monotonic - lastMono < interval { return }
        if wall < cooldownUntil {
            failureStreak += 1
            lastMono = monotonic
            return
        }
        refreshing = true
        refresh(monotonic: monotonic, wall: wall)
    }

    public func grokFields(at now: TimeInterval) -> GrokQuotaFields {
        guard provider == .grok else { return GrokQuotaFields() }
        let lane = wire("credit", now: now)
        var fields = GrokQuotaFields()
        fields.grokCreditPct = lane.pct
        fields.grokCreditResetMin = lane.reset
        fields.grokCreditStale = lane.stale
        fields.grokQuotaLabel = label
        return fields
    }

    public func cursorFields(at now: TimeInterval) -> CursorQuotaFields {
        guard provider == .cursor else { return CursorQuotaFields() }
        var fields = CursorQuotaFields()
        let total = wire("total", now: now)
        fields.cursorTotalPct = total.pct
        fields.cursorTotalResetMin = total.reset
        fields.cursorTotalStale = total.stale
        let models = wire("models", now: now)
        fields.cursorModelsPct = models.pct
        fields.cursorModelsResetMin = models.reset
        fields.cursorModelsStale = models.stale
        let third = wire("third", now: now)
        fields.cursorThirdPct = third.pct
        fields.cursorThirdResetMin = third.reset
        fields.cursorThirdStale = third.stale
        let bot = wire("bot", now: now)
        fields.cursorBotPct = bot.pct
        fields.cursorBotResetMin = bot.reset
        fields.cursorBotStale = bot.stale
        return fields
    }

    public func diagnostics(monotonic: TimeInterval, wall: TimeInterval) -> SubscriptionDiagnostics {
        let left = cooldownUntil - wall
        let age = lastMono == 0 ? nil : Int((monotonic - lastMono).rounded(.towardZero))
        return SubscriptionDiagnostics(
            status: status,
            interval: Int(interval.rounded(.towardZero)),
            cooldownLeft: left > 0 ? Int(ceil(left)) : nil,
            age: age
        )
    }

    private func sample(at wall: TimeInterval) -> SubscriptionSample {
        do {
            return try fetch(wall)
        } catch {
            return SubscriptionSample(
                auth: auth,
                status: "probe_crashed: \(String(describing: type(of: error)))",
                summary: "transport",
                sand: "failed"
            )
        }
    }

    private func note(_ raw: SubscriptionSample, wall: TimeInterval) {
        auth = raw.auth.isEmpty ? "missing" : raw.auth
        if provider == .grok {
            noteGrok(raw, wall: wall)
        } else {
            noteCursor(raw, wall: wall)
        }
    }

    private func noteGrok(_ raw: SubscriptionSample, wall: TimeInterval) {
        let kind = raw.status ?? raw.summary ?? "transport"
        if kind == "ok", let reading = raw.reading {
            lanes["credit"] = Lane(pct: reading.pct, resetAt: reading.resetAt, stale: false)
            label = reading.label ?? "CREDITS"
            failureStreak = 0
            cooldownUntil = 0
            status = "usage_http_200 + ok"
            return
        }
        if kind == "unmapped" {
            lanes["credit"] = nil
            label = nil
            failureStreak += 1
            status = "usage_http_200 + no_mapped_limits"
            return
        }
        if kind == "rate_limited" {
            markStale(["credit"])
            let retry = raw.retryAfter
            cooldownUntil = wall + Double(max(retry, Int(Self.rateLimitFloor)))
            failureStreak += 1
            status = "usage_http_429 + backoff_until_\(ProbeClock.hhmm(cooldownUntil))"
            return
        }
        if kind == "transport" {
            markStale(["credit"])
            failureStreak += 1
            status = "usage_request_failed"
            return
        }
        markStale(["credit"])
        failureStreak = 0
        status = kind
    }

    private func noteCursor(_ raw: SubscriptionSample, wall: TimeInterval) {
        let summary = raw.summary ?? "skipped"
        let sand = raw.sand ?? "skipped"
        if summary == "ok" || summary == "unmapped" {
            for name in ["total", "models", "third"] {
                let reading = named(name, in: raw) ?? SubscriptionReading()
                lanes[name] = Lane(pct: reading.pct, resetAt: reading.resetAt, stale: false)
            }
        } else {
            var stale = ["total", "models", "third"]
            if sand == "skipped" { stale.append("bot") }
            markStale(stale)
        }
        if (sand == "ok" || sand == "none"), let bot = raw.bot {
            lanes["bot"] = Lane(pct: bot.pct, resetAt: bot.resetAt, stale: false)
        } else if sand == "failed" || sand == "rate_limited" {
            markStale(["bot"])
        }
        if summary == "rate_limited" || sand == "rate_limited" {
            cooldownUntil = wall + Double(max(raw.retryAfter, Int(Self.rateLimitFloor)))
            failureStreak += 1
            status = "usage_http_429 + backoff_until_\(ProbeClock.hhmm(cooldownUntil))"
            return
        }
        if summary == "transport" {
            failureStreak += 1
            status = "usage_request_failed"
            return
        }
        if summary == "unauthorized" {
            failureStreak = 0
            status = "token_dead_awaiting_refresh"
            return
        }
        if summary == "skipped" {
            failureStreak = 0
            status = auth == "expired" ? "token_expired" : "no_cursor_session"
            return
        }
        if summary == "unmapped" {
            failureStreak += 1
            status = "usage_http_200 + no_mapped_limits"
            return
        }
        failureStreak = 0
        cooldownUntil = 0
        let suffix = (sand == "ok" || sand == "none" || sand == "skipped") ? "" : "; sand_failed"
        status = "usage_http_200 + ok" + suffix
    }

    private func named(_ name: String, in raw: SubscriptionSample) -> SubscriptionReading? {
        switch name {
        case "total": return raw.total
        case "models": return raw.models
        case "third": return raw.third
        default: return raw.bot
        }
    }

    private func markStale(_ names: [String]) {
        for name in names {
            guard var lane = lanes[name], lane.pct != nil else { continue }
            lane.stale = true
            lanes[name] = lane
        }
    }

    private func wire(_ name: String, now: TimeInterval) -> (pct: Double?, reset: Int?, stale: Bool) {
        guard let lane = lanes[name], let pct = lane.pct else { return (nil, nil, false) }
        if let reset = lane.resetAt, reset <= now { return (nil, nil, false) }
        let minutes: Int?
        if let reset = lane.resetAt, reset > now {
            minutes = Int(floor((reset - now) / 60))
        } else {
            minutes = nil
        }
        return (pct, minutes, lane.stale)
    }

    private struct Lane {
        var pct: Double?
        var resetAt: TimeInterval?
        var stale: Bool
    }
}

public enum SubscriptionFetch {
    public static func grok(auth: GrokAuth, now: TimeInterval, transport: any QuotaHTTPTransport) -> SubscriptionSample {
        if auth.status == "expired" {
            return SubscriptionSample(auth: "expired", status: "token_expired")
        }
        guard auth.status == "ready", let token = auth.accessToken else {
            let word: String
            switch auth.status {
            case "missing": word = "no_grok_oauth_token"
            case "malformed": word = "grok_auth_malformed"
            case "unreadable": word = "grok_auth_unreadable"
            default: word = "no_grok_oauth_token"
            }
            return SubscriptionSample(auth: "missing", status: word)
        }
        let result = QuotaHTTP.exchange(
            url: GrokBilling.billingURL,
            headers: [
                "Authorization": "Bearer \(token)",
                "x-xai-token-auth": "xai-grok-cli",
                "Accept": "application/json",
                "User-Agent": "vibepulse",
            ],
            timeout: 15,
            now: now,
            transport: transport
        )
        if result.status == 429 {
            return SubscriptionSample(auth: "ready", status: "rate_limited", retryAfter: result.retryAfter)
        }
        if result.status == 401 || result.status == 403 {
            return SubscriptionSample(auth: "unauthorized", status: "token_dead_awaiting_refresh")
        }
        guard result.status == 200, let payload = result.payload, let data = jsonData(payload) else {
            return SubscriptionSample(auth: "ready", status: "transport")
        }
        guard let reading = GrokBilling.rawReading(data) else {
            return SubscriptionSample(auth: "ready", status: "unmapped")
        }
        return SubscriptionSample(
            auth: "ready",
            status: "ok",
            reading: SubscriptionReading(pct: reading.pct, resetAt: reading.resetAt, label: reading.label)
        )
    }

    public static func cursor(status: String, token: String?, now: TimeInterval, transport: any QuotaHTTPTransport) -> SubscriptionSample {
        if status == "expired" {
            return SubscriptionSample(auth: "expired", summary: "skipped", sand: "skipped")
        }
        guard status == "ready", let token, let cookie = CursorUsage.sessionCookie(token) else {
            return SubscriptionSample(auth: "missing", summary: "skipped", sand: "skipped")
        }
        let headers = [
            "Cookie": cookie,
            "Accept": "application/json",
            "User-Agent": "vibepulse",
        ]
        let summary = QuotaHTTP.exchange(url: CursorUsage.usageURL, headers: headers, timeout: 15, now: now, transport: transport)
        var sample = SubscriptionSample(auth: "ready", sand: "skipped", retryAfter: summary.retryAfter)
        if summary.status == 429 {
            sample.summary = "rate_limited"
            return sample
        }
        if summary.status == 401 || summary.status == 403 {
            sample.auth = "unauthorized"
            sample.summary = "unauthorized"
            return sample
        }
        if summary.status != 200 || summary.payload == nil {
            sample.summary = "transport"
            return sample
        }
        if let payload = summary.payload, let data = jsonData(payload), let lanes = CursorUsage.rawSummary(data) {
            sample.summary = "ok"
            sample.total = SubscriptionReading(pct: lanes.total.pct, resetAt: lanes.total.resetAt)
            sample.models = SubscriptionReading(pct: lanes.models.pct, resetAt: lanes.models.resetAt)
            sample.third = SubscriptionReading(pct: lanes.third.pct, resetAt: lanes.third.resetAt)
        } else {
            sample.summary = "unmapped"
        }
        var sandHeaders = headers
        sandHeaders["Origin"] = "https://cursor.com"
        sandHeaders["Content-Type"] = "application/json"
        let sand = QuotaHTTP.exchange(
            url: CursorUsage.sandURL,
            method: "POST",
            headers: sandHeaders,
            body: Data("{}".utf8),
            timeout: 15,
            now: now,
            transport: transport
        )
        if sand.status == 200, let payload = sand.payload, let data = jsonData(payload) {
            let bot = CursorUsage.rawSand(data, now: now)
            sample.sand = bot.pct == nil ? "none" : "ok"
            sample.bot = SubscriptionReading(pct: bot.pct, resetAt: bot.resetAt)
        } else {
            sample.sand = "failed"
            if sand.status == 429 {
                sample.retryAfter = max(sample.retryAfter, sand.retryAfter)
                sample.sand = "rate_limited"
            }
        }
        return sample
    }

    private static func jsonData(_ payload: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(payload) else { return nil }
        return try? JSONSerialization.data(withJSONObject: payload)
    }
}
