import Foundation

/// What the forecast says about a weekly window, in the app's own words.
public enum PaceNote: Sendable, Equatable {
    /// Runs out this many minutes before the window resets.
    case runsOutEarly(minutesBeforeReset: Int, minutesFromNow: Int?)
    /// Lasts to the reset, landing at this projected usage.
    case lastsToReset(projectedPercent: Int)
    case collecting
}

public struct QuotaMetric: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var window: QuotaWindow
    public var delta: Double?
    public var deltaCaption: String?
    public var pace: PaceNote?

    public init(id: String, title: String, window: QuotaWindow, delta: Double? = nil,
                deltaCaption: String? = nil, pace: PaceNote? = nil) {
        self.id = id
        self.title = title
        self.window = window
        self.delta = delta
        self.deltaCaption = deltaCaption
        self.pace = pace
    }

    public var usedPercent: Double? { self.window.usedPercent.map { min(100, max(0, $0)) } }
    public var remainingPercent: Double? { self.usedPercent.map { 100 - $0 } }
}

/// One provider's quota picture, normalized from `/api/tokens`.
public struct ProviderUsage: Sendable, Equatable {
    public var provider: Provider
    public var metrics: [QuotaMetric]

    public var hasData: Bool { self.metrics.contains { $0.window.hasData } }
    public var isStale: Bool { self.metrics.contains { $0.window.stale } }

    /// The window that decides whether a long task fits: the most used one.
    public var mostConstrained: QuotaMetric? {
        self.metrics.filter { $0.usedPercent != nil }.max { ($0.usedPercent ?? 0) < ($1.usedPercent ?? 0) }
    }

    /// The panel's hero window for this provider.
    public var primary: QuotaMetric? {
        switch self.provider {
        case .claude:
            let model = self.metrics.first { $0.id == "claude.modelWeek" }
            if let model, model.window.hasData { return model }
            return self.metrics.first { $0.id == "claude.week" }
        case .codex:
            return self.metrics.first { $0.id == "codex.week" }
        case .grok, .cursor:
            return self.metrics.first
        }
    }

    /// The short window, when the provider has one.
    public var session: QuotaMetric? {
        self.metrics.first { $0.id.hasSuffix(".session") }
    }

    public static func build(_ provider: Provider, from tokens: TokensSnapshot?) -> ProviderUsage {
        guard let tokens else {
            return ProviderUsage(provider: provider, metrics: Self.placeholderMetrics(provider))
        }
        switch provider {
        case .claude:
            return ProviderUsage(provider: provider, metrics: [
                QuotaMetric(id: "claude.session", title: "Session", window: tokens.claudeSession,
                            delta: tokens.claudeSessionHourDelta, deltaCaption: "last hour"),
                QuotaMetric(id: "claude.week", title: "Weekly", window: tokens.claudeWeek,
                            delta: tokens.claudeWeekTodayDelta, deltaCaption: "today",
                            pace: Self.pace(tokens.claudeForecast, window: tokens.claudeWeek)),
                QuotaMetric(id: "claude.modelWeek",
                            title: Self.titleCase(tokens.claudeModelWeekLabel) ?? "Model weekly",
                            window: tokens.claudeModelWeek,
                            delta: tokens.claudeModelWeekTodayDelta, deltaCaption: "today"),
            ])
        case .codex:
            return ProviderUsage(provider: provider, metrics: [
                QuotaMetric(id: "codex.session", title: "Session", window: tokens.codexSession),
                QuotaMetric(id: "codex.week", title: "Weekly", window: tokens.codexWeek,
                            delta: tokens.codexWeekTodayDelta, deltaCaption: "today",
                            pace: Self.pace(tokens.codexForecast, window: tokens.codexWeek)),
            ])
        case .grok:
            let label = Self.titleCase(tokens.grokQuotaLabel) ?? "Credits"
            let title = label == "Credits" ? label : "\(label) credits"
            return ProviderUsage(provider: provider, metrics: [
                QuotaMetric(id: "grok.credits", title: title, window: tokens.grokCredit),
            ])
        case .cursor:
            return ProviderUsage(provider: provider, metrics: [
                QuotaMetric(id: "cursor.total", title: "Total", window: tokens.cursorTotal),
                QuotaMetric(id: "cursor.models", title: "Cursor models", window: tokens.cursorModels),
                QuotaMetric(id: "cursor.third", title: "Third party", window: tokens.cursorThird),
                QuotaMetric(id: "cursor.bot", title: "Grok Bot", window: tokens.cursorBot),
            ])
        }
    }

    private static func placeholderMetrics(_ provider: Provider) -> [QuotaMetric] {
        let empty = QuotaWindow(usedPercent: nil, resetMinutes: nil)
        switch provider {
        case .claude:
            return [
                QuotaMetric(id: "claude.session", title: "Session", window: empty),
                QuotaMetric(id: "claude.week", title: "Weekly", window: empty),
            ]
        case .codex:
            return [
                QuotaMetric(id: "codex.session", title: "Session", window: empty),
                QuotaMetric(id: "codex.week", title: "Weekly", window: empty),
            ]
        case .grok:
            return [QuotaMetric(id: "grok.credits", title: "Credits", window: empty)]
        case .cursor:
            return [QuotaMetric(id: "cursor.total", title: "Total", window: empty)]
        }
    }

    /// Only an EXHAUSTS forecast that lands strictly before the reset is a
    /// warning; "at reset" means the reset is the wall. A forecast is never
    /// shown under a percentage it does not measure.
    static func pace(_ forecast: Forecast, window: QuotaWindow) -> PaceNote? {
        guard window.hasData, !window.stale else { return nil }
        switch forecast.state {
        case .exhausts:
            guard let offset = forecast.offsetMinutes, offset < 0 else { return nil }
            let fromNow = window.resetMinutes.map { $0 + offset }
            if let fromNow, fromNow <= 0 { return nil }
            return .runsOutEarly(minutesBeforeReset: -offset, minutesFromNow: fromNow)
        case .atReset:
            return forecast.pctAtReset.map { .lastsToReset(projectedPercent: $0) }
        case .collecting:
            return .collecting
        case .unavailable, .none:
            return nil
        }
    }

    /// "FABLE · WEEK" → "Fable · Week"; model ids keep their digits.
    static func titleCase(_ label: String?) -> String? {
        guard let label = label?.trimmingCharacters(in: .whitespaces), !label.isEmpty else { return nil }
        return label.split(separator: " ", omittingEmptySubsequences: false).map { word in
            guard let first = word.first else { return String(word) }
            return first.uppercased() + word.dropFirst().lowercased()
        }.joined(separator: " ")
    }
}
