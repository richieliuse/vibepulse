import Foundation

public struct CodexQuota: Equatable {
    public var codexWeekPct: Double?
    public var codexWeekResetAt: Int?
    public var codexWeekObservedAt: Int?
    public var codexWeekIdentity: String?
    public var codexWeekStale: Bool?
    public var codexWeekWindowMinutes: Double?
    public var codexSessionPct: Double?
    public var codexSessionResetMin: Int?
    public var codexSessionWindowMinutes: Double?

    public init() {}

    public var isEmpty: Bool { codexWeekPct == nil }
}

public struct CodexAppServerWindow: Equatable {
    public var usedPercent: Double?
    public var windowDurationMins: Int
    public var resetsAt: Double?

    public init(usedPercent: Double?, windowDurationMins: Int, resetsAt: Double?) {
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
    }
}

public struct CodexAppServerBody: Equatable {
    public var primary: CodexAppServerWindow?
    public var secondary: CodexAppServerWindow?

    public init(primary: CodexAppServerWindow?, secondary: CodexAppServerWindow?) {
        self.primary = primary
        self.secondary = secondary
    }
}

public struct CodexAuth: Equatable, CustomStringConvertible {
    public var status: String
    public var accessToken: String?
    public var accountID: String?
    public var expiresAt: Double?

    public init(status: String, accessToken: String? = nil, accountID: String? = nil, expiresAt: Double? = nil) {
        self.status = status
        self.accessToken = accessToken
        self.accountID = accountID
        self.expiresAt = expiresAt
    }

    public var description: String {
        "AuthView(status=\"\(status)\", has_token=\(accessToken != nil), has_account=\(accountID != nil))"
    }
}

public struct CodexRolloutUsage: Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheWriteInputTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, cacheWriteInputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
    }
}

public enum CodexOAuth {
    public static let defaultUsageURL = "https://chatgpt.com/backend-api/wham/usage"
    public static let maxAuthBytes = 256 * 1024

    public static func usageURL(base: String?) -> String? {
        guard var text = base?.trimmingCharacters(in: .whitespacesAndNewlines) else { return defaultUsageURL }
        while text.hasSuffix("/") { text.removeLast() }
        if text.isEmpty { return defaultUsageURL }
        guard let parts = URLComponents(string: text), parts.scheme == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              (parts.query ?? "").isEmpty, parts.fragment == nil else { return nil }
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        let usagePath: String
        if path.hasSuffix("/wham/usage") || path.hasSuffix("/api/codex/usage") {
            usagePath = path
        } else if path.contains("/backend-api") {
            usagePath = path + "/wham/usage"
        } else {
            usagePath = path + "/api/codex/usage"
        }
        var netloc = host
        if let port = parts.port { netloc += ":\(port)" }
        return "https://\(netloc)\(usagePath)"
    }

    public static func baseURL(fromConfig text: String) -> String? {
        let pattern = #"^[ \t]*chatgpt_base_url[ \t]*=[ \t]*(['"])([^'"]+)\1[ \t]*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, options: [], range: range),
              let valueRange = Range(match.range(at: 2), in: text) else { return nil }
        let value = text[valueRange].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    public static func tokenFingerprint(_ token: String) -> String {
        QuotaIdentity.hex(Data(token.utf8))
    }

    public static func jwtExpiry(_ token: String) -> Double? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let filtered = parts[1].filter { alphabet.contains($0) }
        guard !filtered.isEmpty else { return nil }
        var base64 = String(filtered).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let pad = (4 - base64.count % 4) % 4
        base64 += String(repeating: "=", count: pad)
        guard let data = Data(base64Encoded: base64), let object = JSON.object(from: data),
              let exp = JSON.finite(object["exp"]) else { return nil }
        return exp
    }

    public static func loadAuth(_ data: Data, now: TimeInterval) -> CodexAuth {
        if data.isEmpty || data.count > maxAuthBytes { return CodexAuth(status: "malformed") }
        guard let payload = JSON.object(from: data), let tokens = JSON.dictionary(payload["tokens"]) else {
            return CodexAuth(status: JSON.object(from: data) == nil ? "malformed" : "missing")
        }
        guard let access = JSON.string(tokens["access_token"]) else { return CodexAuth(status: "missing") }
        if access.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || access.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) {
            return CodexAuth(status: "missing")
        }
        let account = JSON.string(tokens["account_id"])
        let accountID = (account?.isEmpty == false) ? account : nil
        let expires = jwtExpiry(access)
        if let expires, expires <= now {
            return CodexAuth(status: "expired", expiresAt: expires)
        }
        return CodexAuth(status: "ready", accessToken: access, accountID: accountID, expiresAt: expires)
    }

    public static func loadAuth(path: URL, now: TimeInterval) -> CodexAuth {
        guard FileManager.default.fileExists(atPath: path.path) else { return CodexAuth(status: "missing") }
        guard let data = try? Data(contentsOf: path) else { return CodexAuth(status: "malformed") }
        if data.isEmpty || data.count > maxAuthBytes { return CodexAuth(status: "malformed") }
        return loadAuth(data, now: now)
    }

    /// Map a wham/usage document onto the app-server window shape. `18001` seconds is dropped.
    public static func appServerBody(_ data: Data) -> CodexAppServerBody? {
        guard let payload = JSON.object(from: data), let rate = JSON.dictionary(payload["rate_limit"]) else { return nil }
        let primary = httpWindow(rate["primary_window"])
        let secondary = httpWindow(rate["secondary_window"])
        if primary == nil && secondary == nil { return nil }
        return CodexAppServerBody(primary: primary, secondary: secondary)
    }

    public static func parseWhamUsage(_ data: Data, observedAt: Int, now: TimeInterval) -> CodexQuota {
        guard let body = appServerBody(data) else { return CodexQuota() }
        return parse(appServer: body, observedAt: observedAt, now: now)
    }

    public static func parse(appServer body: CodexAppServerBody, observedAt: Int, now: TimeInterval) -> CodexQuota {
        let normalized = NormalizedLimits(
            limitID: nil,
            limitName: .absent,
            primary: body.primary.map { snake($0) },
            secondary: body.secondary.map { snake($0) }
        )
        return classify(normalized, observedAt: observedAt, now: now)
    }

    private static func httpWindow(_ value: Any?) -> CodexAppServerWindow? {
        guard let window = JSON.dictionary(value), let minutes = minuteWindow(window["limit_window_seconds"]) else { return nil }
        return CodexAppServerWindow(
            usedPercent: JSON.finite(window["used_percent"]),
            windowDurationMins: minutes,
            resetsAt: JSON.finite(window["reset_at"])
        )
    }

    private static func minuteWindow(_ value: Any?) -> Int? {
        guard let seconds = JSON.finite(value), seconds > 0 else { return nil }
        let remainder = seconds.truncatingRemainder(dividingBy: 60)
        guard remainder == 0 else { return nil }
        return Int(seconds / 60)
    }

    private static func snake(_ window: CodexAppServerWindow) -> SnakeWindow {
        SnakeWindow(usedPercent: window.usedPercent, windowMinutes: Double(window.windowDurationMins), resetsAt: window.resetsAt)
    }
}

public enum CodexRateLimits {
    /// `account/rateLimits/read` result, or the camelCase body `appServerBody` produces.
    public static func parseResponse(_ data: Data, observedAt: Int, now: TimeInterval) -> CodexQuota {
        guard let body = JSON.object(from: data) else { return CodexQuota() }
        let buckets = JSON.dictionary(body["rateLimitsByLimitId"])
        let selected = JSON.dictionary(buckets?["codex"]) ?? JSON.dictionary(body["rateLimits"])
        guard let selected else { return CodexQuota() }
        let normalized = NormalizedLimits(
            limitID: JSON.string(selected["limitId"]),
            limitName: limitName(selected["limitName"]),
            primary: snake(camel: selected["primary"]),
            secondary: snake(camel: selected["secondary"])
        )
        return classify(normalized, observedAt: observedAt, now: now)
    }

    private static func limitName(_ value: Any?) -> LimitName {
        if value == nil || value is NSNull { return .absent }
        if let text = value as? String { return text.isEmpty ? .empty : .text(text) }
        return .invalid
    }

    private static func snake(camel value: Any?) -> SnakeWindow? {
        guard let window = JSON.dictionary(value) else { return nil }
        return SnakeWindow(
            usedPercent: JSON.finite(window["usedPercent"]),
            windowMinutes: JSON.finite(window["windowDurationMins"]),
            resetsAt: JSON.finite(window["resetsAt"])
        )
    }
}

public enum CodexRollout {
    public static func rateLimits(in data: Data) -> Bool {
        guard let object = JSON.object(from: data) else { return false }
        return rateLimitsObject(object) != nil
    }

    public static func observationTimestamp(_ value: Any?, naiveZone: TimeZone = .current) -> Int? {
        guard let text = JSON.string(value), let instant = Instants.parse(text, naiveZone: naiveZone) else { return nil }
        return Int(exactly: instant.rounded(.towardZero))
    }

    public static func sessionID(in data: Data) -> String? {
        guard let object = JSON.object(from: data), JSON.string(object["type"]) == "session_meta",
              let payload = JSON.dictionary(object["payload"]),
              let session = JSON.string(payload["session_id"]), !session.isEmpty else { return nil }
        return session
    }

    public static func turnModel(in data: Data) -> String? {
        guard let object = JSON.object(from: data), JSON.string(object["type"]) == "turn_context",
              let payload = JSON.dictionary(object["payload"]),
              let model = JSON.string(payload["model"]), !model.isEmpty else { return nil }
        return model
    }

    public static func lastTokenUsage(in data: Data) -> CodexRolloutUsage? {
        guard let object = JSON.object(from: data),
              let info = tokenInfo(object),
              let usage = JSON.dictionary(info["last_token_usage"]) else { return nil }
        return CodexRolloutUsage(
            inputTokens: intField(usage["input_tokens"]),
            outputTokens: intField(usage["output_tokens"]),
            cacheWriteInputTokens: intField(usage["cache_write_input_tokens"])
        )
    }

    /// One rollout line → the same panel fields as the rate-limits response, when the envelope matches.
    public static func parseLine(_ data: Data, now: TimeInterval, naiveZone: TimeZone = .current) -> CodexQuota {
        guard let object = JSON.object(from: data), let limits = rateLimitsObject(object),
              let observed = observationTimestamp(object["timestamp"], naiveZone: naiveZone) else { return CodexQuota() }
        let normalized = NormalizedLimits(
            limitID: JSON.string(limits["limit_id"]),
            limitName: {
                if limits["limit_name"] == nil || limits["limit_name"] is NSNull { return .absent }
                if let text = limits["limit_name"] as? String { return text.isEmpty ? .empty : .text(text) }
                return .invalid
            }(),
            primary: snake(rollout: limits["primary"]),
            secondary: snake(rollout: limits["secondary"])
        )
        return classify(normalized, observedAt: observed, now: now)
    }

    /// Week and session windows from one rollout line, independently. A named quota
    /// yields no week, so a newer named event cannot hide an older general one.
    static func lineHit(_ data: Data, now: TimeInterval, naiveZone: TimeZone = .current) -> CodexLineHit? {
        guard let object = JSON.object(from: data), let limits = rateLimitsObject(object),
              let observed = observationTimestamp(object["timestamp"], naiveZone: naiveZone) else { return nil }
        let normalized = NormalizedLimits(
            limitID: JSON.string(limits["limit_id"]),
            limitName: {
                if limits["limit_name"] == nil || limits["limit_name"] is NSNull { return .absent }
                if let text = limits["limit_name"] as? String { return text.isEmpty ? .empty : .text(text) }
                return .invalid
            }(),
            primary: snake(rollout: limits["primary"]),
            secondary: snake(rollout: limits["secondary"])
        )
        let week = generalObservation(normalized, observedAt: observed, now: now)
        let session = sessionObservation(normalized, now: now)
        if week == nil && session == nil { return nil }
        return CodexLineHit(
            limitID: normalized.limitID,
            observedAt: observed,
            weekPct: week?.pct,
            weekResetAt: week?.resetAt,
            weekWindowMinutes: week?.windowMinutes,
            sessionPct: session?.pct,
            sessionResetMin: session?.resetMin,
            sessionWindowMinutes: session?.windowMinutes
        )
    }

    private static func rateLimitsObject(_ object: [String: Any]) -> [String: Any]? {
        guard JSON.string(object["type"]) == "event_msg",
              let payload = JSON.dictionary(object["payload"]),
              JSON.string(payload["type"]) == "token_count",
              let limits = JSON.dictionary(payload["rate_limits"]) else { return nil }
        return limits
    }

    private static func tokenInfo(_ object: [String: Any]) -> [String: Any]? {
        guard JSON.string(object["type"]) == "event_msg",
              let payload = JSON.dictionary(object["payload"]),
              JSON.string(payload["type"]) == "token_count" else { return nil }
        return JSON.dictionary(payload["info"])
    }

    private static func snake(rollout value: Any?) -> SnakeWindow? {
        guard let window = JSON.dictionary(value) else { return nil }
        return SnakeWindow(
            usedPercent: JSON.finite(window["used_percent"]),
            windowMinutes: JSON.finite(window["window_minutes"]),
            resetsAt: JSON.finite(window["resets_at"])
        )
    }

    private static func intField(_ value: Any?) -> Int? {
        guard let number = JSON.finite(value), let int = Int(exactly: number.rounded(.towardZero)) else { return nil }
        return int
    }
}

struct CodexLineHit {
    var limitID: String?
    var observedAt: Int
    var weekPct: Double?
    var weekResetAt: Int?
    var weekWindowMinutes: Double?
    var sessionPct: Double?
    var sessionResetMin: Int?
    var sessionWindowMinutes: Double?
}

enum LimitName: Equatable {
    case absent
    case empty
    case text(String)
    case invalid
}

struct SnakeWindow: Equatable {
    var usedPercent: Double?
    var windowMinutes: Double?
    var resetsAt: Double?
}

struct NormalizedLimits {
    var limitID: String?
    var limitName: LimitName
    var primary: SnakeWindow?
    var secondary: SnakeWindow?
}

private struct ParsedWindow {
    var pct: Double
    var resetMin: Int
    var windowMinutes: Double
    var resetAt: Int
}

func classify(_ limits: NormalizedLimits, observedAt: Int, now: TimeInterval) -> CodexQuota {
    guard let weekly = generalObservation(limits, observedAt: observedAt, now: now) else { return CodexQuota() }
    var out = CodexQuota()
    out.codexWeekPct = weekly.pct
    out.codexWeekResetAt = weekly.resetAt
    out.codexWeekObservedAt = observedAt
    out.codexWeekIdentity = QuotaIdentity.make(provider: "codex", scope: "general_weekly", raw: limits.limitID)
    out.codexWeekStale = false
    out.codexWeekWindowMinutes = weekly.windowMinutes
    if let session = sessionObservation(limits, now: now) {
        out.codexSessionPct = session.pct
        out.codexSessionResetMin = session.resetMin
        out.codexSessionWindowMinutes = session.windowMinutes
    }
    return out
}

private func generalObservation(_ limits: NormalizedLimits, observedAt: Int, now: TimeInterval) -> ParsedWindow? {
    switch limits.limitName {
    case .absent, .empty: break
    case .text, .invalid: return nil
    }
    for window in [limits.primary, limits.secondary] {
        guard let parsed = codexWindow(window, now: now), parsed.windowMinutes == 10080 else { continue }
        return parsed
    }
    return nil
}

private func sessionObservation(_ limits: NormalizedLimits, now: TimeInterval) -> ParsedWindow? {
    for window in [limits.primary, limits.secondary] {
        guard let parsed = codexWindow(window, now: now), parsed.windowMinutes <= 600 else { continue }
        return parsed
    }
    return nil
}

private func codexWindow(_ window: SnakeWindow?, now: TimeInterval) -> ParsedWindow? {
    guard let window, let pct = window.usedPercent, (0...100).contains(pct),
          let minutes = window.windowMinutes, minutes.isFinite,
          let resets = window.resetsAt, resets.isFinite, resets > now,
          let resetAt = Int(exactly: resets.rounded(.towardZero)) else { return nil }
    let resetMin = max(0, ResetTime.roundInt((Double(resetAt) - now) / 60))
    return ParsedWindow(pct: ResetTime.round1(pct), resetMin: resetMin, windowMinutes: minutes, resetAt: resetAt)
}
