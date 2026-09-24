import Foundation

public struct CursorQuotaFields: Equatable {
    public var cursorTotalPct: Double?
    public var cursorTotalResetMin: Int?
    public var cursorTotalStale: Bool = false
    public var cursorModelsPct: Double?
    public var cursorModelsResetMin: Int?
    public var cursorModelsStale: Bool = false
    public var cursorThirdPct: Double?
    public var cursorThirdResetMin: Int?
    public var cursorThirdStale: Bool = false
    public var cursorBotPct: Double?
    public var cursorBotResetMin: Int?
    public var cursorBotStale: Bool = false

    public init() {}
}

public struct GrokQuotaFields: Equatable {
    public var grokCreditPct: Double?
    public var grokCreditResetMin: Int?
    public var grokCreditStale: Bool = false
    public var grokQuotaLabel: String?

    public init() {}
}

public struct GrokAuth: Equatable, CustomStringConvertible {
    public var status: String
    public var accessToken: String?

    public init(status: String, accessToken: String? = nil) {
        self.status = status
        self.accessToken = accessToken
    }

    public var description: String {
        "AuthView(status=\"\(status)\", has_token=\(accessToken != nil))"
    }
}

public enum PercentParsing {
    public static func asPercent(_ value: Any?) -> Double? {
        guard let number = JSON.finite(value), number >= 0 else { return nil }
        if number > 1000 { return nil }
        let clamped = number > 100 ? 100 : number
        return ResetTime.round1(clamped)
    }

    /// Epoch seconds. Millisecond numbers and all-digit strings are scaled. Naive ISO is UTC.
    public static func parseTime(_ value: Any?) -> TimeInterval? {
        if JSON.isBool(value) || value == nil || value is NSNull { return nil }
        if let number = JSON.finite(value) { return scale(number) }
        guard var text = JSON.string(value)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.allSatisfy(\.isNumber), let int = RetryAfter.integer(text) { return scale(Double(int)) }
        if text.hasSuffix("Z") {
            text.removeLast()
            text += "+00:00"
        }
        guard let instant = Instants.parse(text, naiveZone: TimeZone(secondsFromGMT: 0) ?? .gmt) else { return nil }
        return instant
    }

    public static func quotaLabel(start: TimeInterval?, end: TimeInterval?) -> String {
        guard let start, let end, end > start else { return "CREDITS" }
        let days = (end - start) / 86400
        if (6...8).contains(days) { return "WEEKLY" }
        if (27...32).contains(days) { return "MONTHLY" }
        return "CREDITS"
    }

    private static func scale(_ stamp: Double) -> TimeInterval? {
        var value = stamp
        if value > 10_000_000_000 { value /= 1000 }
        if value < 1_000_000_000 { return nil }
        return value
    }
}

struct RawLane {
    var pct: Double?
    var resetAt: TimeInterval?

    init(pct: Double? = nil, resetAt: TimeInterval? = nil) {
        self.pct = pct
        self.resetAt = resetAt
    }
}

public enum CursorUsage {
    public static let usageURL = "https://cursor.com/api/usage-summary"
    public static let sandURL = "https://cursor.com/api/dashboard/get-sand-usage-status"
    public static let tokenKey = "cursorAuth/accessToken"
    public static let skewSeconds: TimeInterval = 60

    public static func decodeToken(_ raw: Data) -> String? {
        let text: String
        if raw.starts(with: [0xFF, 0xFE]) || utf16LEASCII(raw) {
            text = String(data: raw, encoding: .utf16LittleEndian) ?? ""
        } else {
            text = String(decoding: raw, as: UTF8.self)
        }
        return cleanup(text)
    }

    public static func decodeToken(_ raw: String) -> String? { cleanup(raw) }

    public static func sessionUserID(_ token: String) -> String? {
        guard let object = jwtObject(token), let subject = JSON.string(object["sub"]) else { return nil }
        let userID = subject.split(separator: "|").last.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !userID.isEmpty, userID.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else { return nil }
        return userID
    }

    public static func sessionCookie(_ token: String) -> String? {
        guard let userID = sessionUserID(token) else { return nil }
        return "WorkosCursorSessionToken=\(userID)%3A%3A\(token)"
    }

    public static func load(data: Data?, now: TimeInterval) -> (status: String, token: String?) {
        guard let data, let token = decodeToken(data), token.filter({ $0 == "." }).count >= 2 else {
            return ("missing", nil)
        }
        let expires = CodexOAuth.jwtExpiry(token)
        if expires == nil || expires! <= now + skewSeconds { return ("expired", nil) }
        return ("ready", token)
    }

    public static func load(using reader: any CursorStateReading, path: String, now: TimeInterval) -> (status: String, token: String?) {
        load(data: reader.value(forKey: tokenKey, inDatabase: path), now: now)
    }

    /// Lanes before the wire hides a passed reset. The subscription probe stores these.
    static func rawSummary(_ data: Data) -> (total: RawLane, models: RawLane, third: RawLane)? {
        guard let parsed = parseSummary(data) else { return nil }
        return (raw(parsed.total), raw(parsed.models), raw(parsed.third))
    }

    static func rawSand(_ data: Data, now: TimeInterval) -> RawLane {
        raw(parseSand(data, now: now))
    }

    private static func raw(_ lane: Lane) -> RawLane {
        RawLane(pct: lane.pct, resetAt: lane.resetAt)
    }

    public static func fields(summary: Data, sand: Data? = nil, now: TimeInterval) -> CursorQuotaFields {
        var wire = CursorQuotaFields()
        let parsed = parseSummary(summary)
        wire = apply(lane: parsed?.total, prefix: "total", now: now, into: wire)
        wire = apply(lane: parsed?.models, prefix: "models", now: now, into: wire)
        wire = apply(lane: parsed?.third, prefix: "third", now: now, into: wire)
        if let sand {
            wire = apply(lane: parseSand(sand, now: now), prefix: "bot", now: now, into: wire)
        }
        return wire
    }

    private struct Lane {
        var pct: Double?
        var resetAt: TimeInterval?
    }

    private struct Summary {
        var total: Lane
        var models: Lane
        var third: Lane
    }

    private static func parseSummary(_ data: Data) -> Summary? {
        guard let payload = JSON.object(from: data), let block = planBlock(payload) else { return nil }
        let reset = PercentParsing.parseTime(payload["billingCycleEnd"])
        return Summary(
            total: lane(block, "totalPercentUsed", reset),
            models: lane(block, "autoPercentUsed", reset),
            third: lane(block, "apiPercentUsed", reset)
        )
    }

    private static func planBlock(_ payload: [String: Any]) -> [String: Any]? {
        if let individual = JSON.dictionary(payload["individualUsage"]), let plan = JSON.dictionary(individual["plan"]) {
            return plan
        }
        return JSON.dictionary(payload["planUsage"])
    }

    private static func lane(_ block: [String: Any], _ key: String, _ resetAt: TimeInterval?) -> Lane {
        if block[key] == nil {
            return Lane(pct: nil, resetAt: block.isEmpty ? nil : resetAt)
        }
        return Lane(pct: PercentParsing.asPercent(block[key]), resetAt: resetAt)
    }

    private static func parseSand(_ data: Data, now: TimeInterval) -> Lane {
        guard let payload = JSON.object(from: data) else { return Lane(pct: nil, resetAt: nil) }
        let hasLimit: Bool?
        if let includedZero = JSON.bool(payload["includedLimitZero"]) {
            hasLimit = !includedZero
        } else if let nonzero = JSON.bool(payload["hasNonZeroIncludedLimit"]) {
            hasLimit = nonzero
        } else {
            hasLimit = nil
        }
        let trial = PercentParsing.parseTime(payload["sandTrialExpiresAt"])
        let hasTrial = hasLimit != true && trial != nil && trial! > now
        if hasLimit != true && !hasTrial { return Lane(pct: nil, resetAt: nil) }
        guard let pct = PercentParsing.asPercent(payload["usagePercent"]) else { return Lane(pct: nil, resetAt: nil) }
        let reset = hasLimit == true ? PercentParsing.parseTime(payload["nextResetTimestampUtc"]) : nil
        return Lane(pct: pct, resetAt: reset)
    }

    private static func apply(lane: Lane?, prefix: String, now: TimeInterval, into wire: CursorQuotaFields) -> CursorQuotaFields {
        var wire = wire
        let hidden = lane == nil || lane?.pct == nil || (lane?.resetAt != nil && lane!.resetAt! <= now)
        let pct = hidden ? nil : lane?.pct
        let reset = hidden ? nil : floorMinutes(lane?.resetAt, now: now)
        switch prefix {
        case "total":
            wire.cursorTotalPct = pct
            wire.cursorTotalResetMin = reset
            wire.cursorTotalStale = false
        case "models":
            wire.cursorModelsPct = pct
            wire.cursorModelsResetMin = reset
            wire.cursorModelsStale = false
        case "third":
            wire.cursorThirdPct = pct
            wire.cursorThirdResetMin = reset
            wire.cursorThirdStale = false
        default:
            wire.cursorBotPct = pct
            wire.cursorBotResetMin = reset
            wire.cursorBotStale = false
        }
        return wire
    }

    private static func floorMinutes(_ resetAt: TimeInterval?, now: TimeInterval) -> Int? {
        guard let resetAt, resetAt > now else { return nil }
        return Int(floor((resetAt - now) / 60))
    }

    private static func cleanup(_ text: String) -> String? {
        let ends = CharacterSet(charactersIn: "\u{0000} \t\r\n")
        var value = text.trimmingCharacters(in: ends)
        if value.count >= 2, value.first == "\"", value.last == "\"" {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func utf16LEASCII(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count % 2 == 0 else { return false }
        for index in stride(from: 1, to: data.count, by: 2) where data[index] != 0 { return false }
        return true
    }

    private static func jwtObject(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let pad = (4 - base64.count % 4) % 4
        base64 += String(repeating: "=", count: pad)
        guard let data = Data(base64Encoded: String(base64)) else { return nil }
        return JSON.object(from: data)
    }
}

public enum GrokBilling {
    public static let billingURL = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
    public static let preferredPrefix = "https://auth.x.ai::"
    public static let maxAuthBytes = 256 * 1024

    public static func loadAuth(_ data: Data, now: TimeInterval) -> GrokAuth {
        if data.isEmpty || data.count > maxAuthBytes { return GrokAuth(status: "malformed") }
        guard let payload = JSON.object(from: data) else { return GrokAuth(status: "malformed") }
        var preferred: [[String: Any]] = []
        var rest: [[String: Any]] = []
        var expired = false
        let names: [String]
        if let ordered = JSON.topLevelKeys(in: data), Set(ordered) == Set(payload.keys) {
            names = ordered
        } else {
            names = Array(payload.keys)
        }
        for name in names {
            guard let value = payload[name] else { continue }
            guard let entry = JSON.dictionary(value), JSON.string(entry["key"]) != nil else { continue }
            if let expires = PercentParsing.parseTime(entry["expires_at"]), expires <= now {
                expired = true
                continue
            }
            if name.hasPrefix(preferredPrefix) { preferred.append(entry) } else { rest.append(entry) }
        }
        for entry in preferred + rest {
            if let token = usable(entry, now: now) { return GrokAuth(status: "ready", accessToken: token) }
        }
        return GrokAuth(status: expired ? "expired" : "missing")
    }

    public static func loadAuth(path: URL, now: TimeInterval) -> GrokAuth {
        guard FileManager.default.fileExists(atPath: path.path) else { return GrokAuth(status: "missing") }
        guard let data = try? Data(contentsOf: path) else { return GrokAuth(status: "unreadable") }
        return loadAuth(data, now: now)
    }

    /// Reading before a passed reset is hidden. The probe applies that rule at wire time.
    static func rawReading(_ data: Data) -> (pct: Double, resetAt: TimeInterval?, label: String)? {
        guard let reading = parseBilling(data) else { return nil }
        return (reading.pct, reading.resetAt, reading.label)
    }

    public static func fields(billing data: Data, now: TimeInterval) -> GrokQuotaFields {
        guard let reading = parseBilling(data) else { return GrokQuotaFields() }
        var wire = GrokQuotaFields()
        if let reset = reading.resetAt, reset <= now {
            return wire
        }
        wire.grokCreditPct = reading.pct
        wire.grokCreditResetMin = floorMinutes(reading.resetAt, now: now)
        wire.grokCreditStale = false
        wire.grokQuotaLabel = reading.label
        return wire
    }

    private struct Reading {
        var pct: Double
        var resetAt: TimeInterval?
        var label: String
    }

    private static func parseBilling(_ data: Data) -> Reading? {
        guard let payload = JSON.object(from: data) else { return nil }
        let config = JSON.dictionary(payload["config"]) ?? [:]
        let pct: Double?
        if config.keys.contains("creditUsagePercent") {
            pct = PercentParsing.asPercent(config["creditUsagePercent"])
        } else if payload.keys.contains("creditUsagePercent") {
            pct = PercentParsing.asPercent(payload["creditUsagePercent"])
        } else {
            let used = money(config["onDemandUsed"]) ?? money(payload["onDemandUsed"])
            let cap = money(config["onDemandCap"]) ?? money(payload["onDemandCap"])
            if let used, let cap, cap > 0 {
                pct = PercentParsing.asPercent(used / cap * 100)
            } else {
                pct = nil
            }
        }
        guard let pct else { return nil }
        let bounds = periodBounds(config)
        return Reading(pct: pct, resetAt: bounds.end, label: PercentParsing.quotaLabel(start: bounds.start, end: bounds.end))
    }

    private static func periodBounds(_ config: [String: Any]) -> (start: TimeInterval?, end: TimeInterval?) {
        var start: TimeInterval?
        var end: TimeInterval?
        if let current = JSON.dictionary(config["currentPeriod"]) {
            start = PercentParsing.parseTime(current["start"])
            end = PercentParsing.parseTime(current["end"])
        }
        if end == nil {
            end = PercentParsing.parseTime(config["billingPeriodEnd"])
            if start == nil { start = PercentParsing.parseTime(config["billingPeriodStart"]) }
        }
        return (start, end)
    }

    private static func money(_ value: Any?) -> Double? {
        let node = JSON.dictionary(value)?["val"] ?? value
        guard let number = JSON.finite(node), number >= 0 else { return nil }
        return number
    }

    private static func usable(_ entry: [String: Any], now: TimeInterval) -> String? {
        guard let token = JSON.string(entry["key"]), !token.hasPrefix("xai-"), token.filter({ $0 == "." }).count >= 2 else { return nil }
        if let expires = PercentParsing.parseTime(entry["expires_at"]), expires <= now { return nil }
        return token
    }

    private static func floorMinutes(_ resetAt: TimeInterval?, now: TimeInterval) -> Int? {
        guard let resetAt, resetAt > now else { return nil }
        return Int(floor((resetAt - now) / 60))
    }
}
