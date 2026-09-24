import Foundation

/// One quota window as served by `/api/tokens`: the wire percentage is how
/// much of the window is already USED, `nil` when the source is absent.
public struct QuotaWindow: Sendable, Equatable {
    public var usedPercent: Double?
    public var resetMinutes: Int?
    public var stale: Bool

    public init(usedPercent: Double?, resetMinutes: Int?, stale: Bool = false) {
        self.usedPercent = usedPercent
        self.resetMinutes = resetMinutes
        self.stale = stale
    }

    public var hasData: Bool { self.usedPercent != nil }
}

public struct Forecast: Sendable, Equatable {
    public enum State: String, Sendable {
        case collecting
        case unavailable
        case atReset = "at_reset"
        case exhausts
    }

    public var state: State?
    public var pctAtReset: Int?
    public var paceFactor: Double?
    public var exhaustsAt: Date?
    /// Minutes between exhaustion and the reset; negative means the window
    /// runs out that many minutes before it resets.
    public var offsetMinutes: Int?

    public init(state: State?, pctAtReset: Int? = nil, paceFactor: Double? = nil,
                exhaustsAt: Date? = nil, offsetMinutes: Int? = nil) {
        self.state = state
        self.pctAtReset = pctAtReset
        self.paceFactor = paceFactor
        self.exhaustsAt = exhaustsAt
        self.offsetMinutes = offsetMinutes
    }
}

public struct ValueMeter: Sendable, Equatable {
    public var valueUSD: Double?
    public var planUSD: Double?
    public var multiple: Double?
    public var state: String?
}

public struct UsageTotalsState: Sendable, Equatable {
    public var state: String?
    public var placeholder: Bool
    public var ageSeconds: Int?
}

/// The `/api/tokens` v2 payload, decoded leniently.
public struct TokensSnapshot: Sendable, Equatable {
    public var dayTokens: Double?
    public var dayTokensPerHour: Double?
    public var daySessions: Int?
    public var monthTokens: Double?
    public var claudeSourcePresent: Bool
    public var value: ValueMeter?
    public var usageTotals: UsageTotalsState?

    public var claudeSession: QuotaWindow
    public var claudeSessionHourDelta: Double?
    public var claudeWeek: QuotaWindow
    public var claudeWeekTodayDelta: Double?
    public var claudeModelWeek: QuotaWindow
    public var claudeModelWeekLabel: String?
    public var claudeModelWeekTodayDelta: Double?
    public var claudeForecast: Forecast

    public var codexSession: QuotaWindow
    public var codexWeek: QuotaWindow
    public var codexWeekTodayDelta: Double?
    public var codexForecast: Forecast

    public var grokCredit: QuotaWindow
    public var grokQuotaLabel: String?

    public var cursorTotal: QuotaWindow
    public var cursorModels: QuotaWindow
    public var cursorThird: QuotaWindow
    public var cursorBot: QuotaWindow

    /// The counters are measurements only when the service says so; a
    /// warm-up placeholder must never be rendered as a zero-token day.
    public var volumeIsMeasured: Bool {
        guard let totals = self.usageTotals else { return true }
        return !totals.placeholder
    }

    public init?(data: Data) {
        guard let reader = JSONReader(data: data) else { return nil }
        self.init(reader: reader)
    }

    init?(reader json: JSONReader) {
        guard json.int("v") == 2 else { return nil }
        self.dayTokens = json.double("dayTokens")
        self.dayTokensPerHour = json.double("dayTokensPerHour")
        self.daySessions = json.int("daySessions")
        self.monthTokens = json.double("monthTokens")
        self.claudeSourcePresent = json.bool("claudeSourcePresent") ?? true
        self.value = json.reader("value").map { value in
            ValueMeter(
                valueUSD: value.double("value_usd"),
                planUSD: value.double("plan_usd"),
                multiple: value.double("multiple"),
                state: value.string("state"))
        }
        self.usageTotals = json.reader("usageTotals").map { totals in
            UsageTotalsState(
                state: totals.string("state"),
                placeholder: totals.bool("placeholder") ?? false,
                ageSeconds: totals.int("ageS") ?? totals.int("sinceS"))
        }

        self.claudeSession = Self.window(json, "claudeSession", hasStale: false)
        self.claudeSessionHourDelta = json.double("claudeSessionHourDeltaPct")
        self.claudeWeek = Self.window(json, "claudeWeek")
        self.claudeWeekTodayDelta = json.double("claudeWeekTodayDeltaPct")
        self.claudeModelWeek = Self.window(json, "claudeModelWeek")
        self.claudeModelWeekLabel = json.string("claudeModelWeekLabel")
        self.claudeModelWeekTodayDelta = json.double("claudeModelWeekTodayDeltaPct")
        self.claudeForecast = Self.forecast(json, "claude")

        self.codexSession = Self.window(json, "codexSession", hasStale: false)
        self.codexWeek = Self.window(json, "codexWeek")
        self.codexWeekTodayDelta = json.double("codexWeekTodayDeltaPct")
        self.codexForecast = Self.forecast(json, "codex")

        self.grokCredit = Self.window(json, "grokCredit")
        self.grokQuotaLabel = json.string("grokQuotaLabel")

        self.cursorTotal = Self.window(json, "cursorTotal")
        self.cursorModels = Self.window(json, "cursorModels")
        self.cursorThird = Self.window(json, "cursorThird")
        self.cursorBot = Self.window(json, "cursorBot")
    }

    private static func window(_ json: JSONReader, _ prefix: String, hasStale: Bool = true) -> QuotaWindow {
        let pct = json.double(prefix + "Pct")
        return QuotaWindow(
            usedPercent: pct,
            resetMinutes: pct == nil ? nil : json.int(prefix + "ResetMin"),
            stale: hasStale && pct != nil && (json.bool(prefix + "Stale") ?? false))
    }

    private static func forecast(_ json: JSONReader, _ prefix: String) -> Forecast {
        Forecast(
            state: json.string(prefix + "ForecastState").flatMap(Forecast.State.init(rawValue:)),
            pctAtReset: json.int(prefix + "ForecastPctAtReset"),
            paceFactor: json.double(prefix + "ForecastPaceFactor"),
            exhaustsAt: json.double(prefix + "ForecastAt").map { Date(timeIntervalSince1970: $0) },
            offsetMinutes: json.int(prefix + "ForecastOffsetMin"))
    }
}
