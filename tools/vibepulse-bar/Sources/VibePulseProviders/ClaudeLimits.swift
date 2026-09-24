import Foundation

/// Mapped Claude usage-limits body and `anthropic-ratelimit-unified-*` headers.
public struct ClaudeUsageLimits: Equatable {
    public var sessionPct: Double?
    public var sessionResetAt: Int?
    public var sessionResetMin: Int?
    public var weekPct: Double?
    public var weekResetAt: Int?
    public var weekResetMin: Int?
    public var weekObservedAt: Int?
    public var weekIdentity: String?
    public var modelPct: Double?
    public var modelResetAt: Int?
    public var modelResetMin: Int?
    public var modelObservedAt: Int?
    public var modelIdentity: String?
    public var modelLabel: String?
    public var unknownBuckets: [String] = []

    public init() {}
}

public enum ClaudeLimits {
    public static let usageURL = "https://api.anthropic.com/api/oauth/usage"

    private static let modelLabels = [
        "fable": "FABLE · WEEK",
        "opus": "OPUS · WEEK",
        "sonnet": "SONNET · WEEK",
    ]

    /// `_parse_usage_limits`. Percent is already 0...100. A reset must be strictly in the future.
    public static func parseUsageLimits(_ data: Data, now: TimeInterval) -> ClaudeUsageLimits {
        guard let body = JSON.object(from: data), let limits = JSON.array(body["limits"]) else {
            return ClaudeUsageLimits()
        }
        var found = ClaudeUsageLimits()
        for item in limits {
            guard let limit = JSON.dictionary(item) else { continue }
            let kind = JSON.string(limit["kind"])
            guard let pct = JSON.finite(limit["percent"]), (0...100).contains(pct) else { continue }
            guard let resetAt = ResetTime.epoch(json: limit["resets_at"], now: now), Double(resetAt) > now else { continue }
            let prefix: String
            if kind == "session" {
                prefix = "session"
            } else if kind == "weekly_all" {
                prefix = "week"
            } else if kind == "weekly_scoped", JSON.bool(limit["is_active"]) == true || pct > 0 {
                let scope = JSON.dictionary(limit["scope"])
                let model = JSON.dictionary(scope?["model"])
                let display = JSON.string(model?["display_name"])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                guard let label = modelLabels[display] else { continue }
                prefix = "model"
                found.modelLabel = label
            } else {
                continue
            }
            store(&found, prefix: prefix, pct: ResetTime.round1(pct), resetAt: resetAt, now: now)
        }
        return found
    }

    /// `_parse_limit_headers`. Utilization at or below 1 is a fraction and is scaled by 100.
    public static func parseLimitHeaders(_ headers: [String: String], now: TimeInterval) -> ClaudeUsageLimits {
        var found = ClaudeUsageLimits()
        var unknown: Set<String> = []
        let pattern = #"^anthropic-ratelimit-unified-(.+?)[-_](utilization|reset|resets[-_]at)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return found
        }
        for (name, value) in headers {
            let range = NSRange(name.startIndex..., in: name)
            guard let match = expression.firstMatch(in: name, options: [], range: range),
                  match.numberOfRanges == 3,
                  let rawRange = Range(match.range(at: 1), in: name),
                  let kindRange = Range(match.range(at: 2), in: name) else { continue }
            let raw = name[rawRange].lowercased()
            let namedModel = ["fable", "opus", "sonnet"].first { raw.contains($0) }
            let window: String
            if raw == "5h" {
                window = "session"
            } else if namedModel != nil || raw.contains("model") {
                window = "model"
                if let namedModel {
                    found.modelLabel = modelLabels[namedModel]
                }
            } else if raw == "7d" || raw == "week" {
                window = "week"
            } else {
                let sanitized = String(raw.unicodeScalars.filter { scalar in
                    let value = scalar.value
                    let digit = value >= 48 && value <= 57
                    let letter = value >= 97 && value <= 122
                    return digit || letter || scalar == "_" || scalar == "-"
                }.prefix(64))
                if !sanitized.isEmpty {
                    unknown.insert(sanitized)
                }
                continue
            }
            let kind = name[kindRange].lowercased()
            if kind == "utilization" {
                guard let pct = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
                let scaled = pct <= 1 ? pct * 100 : pct
                assignPct(&found, window: window, pct: ResetTime.round1(scaled))
            } else if let resetAt = ResetTime.epoch(text: value, now: now) {
                assignReset(&found, window: window, resetAt: resetAt, now: now)
            }
        }
        if !unknown.isEmpty {
            found.unknownBuckets = unknown.sorted()
        }
        stampObservations(&found, now: now)
        return found
    }

    private static func store(_ found: inout ClaudeUsageLimits, prefix: String, pct: Double, resetAt: Int, now: TimeInterval) {
        assignPct(&found, window: prefix, pct: pct)
        assignReset(&found, window: prefix, resetAt: resetAt, now: now)
        stampObservations(&found, now: now)
    }

    private static func assignPct(_ found: inout ClaudeUsageLimits, window: String, pct: Double) {
        switch window {
        case "session": found.sessionPct = pct
        case "week": found.weekPct = pct
        case "model": found.modelPct = pct
        default: break
        }
    }

    private static func assignReset(_ found: inout ClaudeUsageLimits, window: String, resetAt: Int, now: TimeInterval) {
        let minutes = ResetTime.minutes(until: resetAt, now: now)
        switch window {
        case "session":
            found.sessionResetAt = resetAt
            found.sessionResetMin = minutes
        case "week":
            found.weekResetAt = resetAt
            found.weekResetMin = minutes
        case "model":
            found.modelResetAt = resetAt
            found.modelResetMin = minutes
        default:
            break
        }
    }

    private static func stampObservations(_ found: inout ClaudeUsageLimits, now: TimeInterval) {
        let observed = Int(now.rounded(.towardZero))
        if found.weekPct != nil, found.weekResetAt != nil {
            found.weekObservedAt = observed
            found.weekIdentity = QuotaIdentity.make(provider: "claude", scope: "general_weekly")
        }
        if found.modelPct != nil, found.modelResetAt != nil {
            found.modelObservedAt = observed
            found.modelIdentity = QuotaIdentity.make(provider: "claude", scope: "model_weekly")
        }
    }
}
