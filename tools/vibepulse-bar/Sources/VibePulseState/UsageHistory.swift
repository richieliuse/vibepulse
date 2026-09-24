import Darwin
import Foundation
import VibePulseSupport

public struct UsageSample: Equatable, Sendable {
    public var at: Double
    public var provider: String
    public var window: String
    public var pct: Double
    public var reset: Double

    public init(at: Double, provider: String, window: String, pct: Double, reset: Double) {
        self.at = at
        self.provider = provider
        self.window = window
        self.pct = pct
        self.reset = reset
    }
}

public struct Forecast: Equatable, Sendable {
    public var state: String
    public var pctAtReset: Int?
    public var paceFactor: Double?
    public var exhaustsAt: Int?
    public var offsetMinutes: Int?

    public init(state: String, pctAtReset: Int? = nil, paceFactor: Double? = nil,
                exhaustsAt: Int? = nil, offsetMinutes: Int? = nil) {
        self.state = state
        self.pctAtReset = pctAtReset
        self.paceFactor = paceFactor
        self.exhaustsAt = exhaustsAt
        self.offsetMinutes = offsetMinutes
    }
}

/// One OBS-39 row: a live quota percentage below the cached figure for the same reset.
/// Missing evidence is an empty list. Fields are measurements, never a stand-in zero.
public struct QuotaRegression: Equatable, Sendable {
    public var provider: String
    public var scope: String
    public var livePct: Double
    public var cachedPct: Double
    public var resetAt: Int
    public var at: Int

    public static let jsonKeys = ["provider", "scope", "livePct", "cachedPct", "resetAt", "at"]

    public init(provider: String, scope: String, livePct: Double, cachedPct: Double, resetAt: Int, at: Int) {
        self.provider = provider
        self.scope = scope
        self.livePct = livePct
        self.cachedPct = cachedPct
        self.resetAt = resetAt
        self.at = at
    }

    public var jsonObject: StrictJSON.Value {
        .object([
            "provider": .string(provider),
            "scope": .string(scope),
            "livePct": .double(livePct),
            "cachedPct": .double(cachedPct),
            "resetAt": .int(resetAt),
            "at": .int(at),
        ])
    }
}

public final class UsageHistory: @unchecked Sendable {
    public static let sampleInterval: TimeInterval = 900
    public static let retention: TimeInterval = 691_200
    public static let forecastWindow: TimeInterval = 86_400
    public static let minForecastSpan: TimeInterval = 5_400
    public static let minForecastDelta: Double = 1
    public static let resetQuantum: Double = 300

    public let path: URL
    private let now: @Sendable () -> TimeInterval
    private let lock = NSRecursiveLock()
    private var loadError: String?
    private var samples: [UsageSample] = []

    private static let providers: Set<String> = ["claude", "codex"]
    private static let windows: Set<String> = ["session", "week", "model_week"]
    private static let scopeForWindow: [String: String] = [
        "session": "general_session",
        "week": "general_weekly",
        "model_week": "model_weekly",
    ]
    private static let windowLength: [String: Double] = [
        "session": 18_000, "week": 604_800, "model_week": 604_800,
    ]
    private static let sampleKeys: Set<String> = ["at", "provider", "window", "pct", "reset"]

    public init(path: URL, now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.path = path
        self.now = now
        self.samples = load()
    }

    public var records: [UsageSample] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    @discardableResult
    public func record(provider: String, window: String, pct: Double, resetAt: Double, at: Double? = nil) -> Bool {
        recordMany([(provider, window, pct, resetAt)], at: at) > 0
    }

    public func recordMany(_ batch: [(provider: String, window: String, pct: Double, resetAt: Double)],
                           at: Double? = nil) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let raw = at ?? now()
        guard raw.isFinite else { return 0 }
        let timestamp = Double(PyRound.integer(raw))
        let old = samples
        let cutoff = timestamp - Self.retention
        samples = samples.filter { $0.at >= cutoff }
        var added = 0
        for item in batch {
            guard Self.providers.contains(item.provider), Self.windows.contains(item.window),
                  item.pct.isFinite, (0...100).contains(item.pct), item.resetAt.isFinite else { continue }
            let cycle = Self.resetCycle(item.resetAt)
            let previous = samples.reversed().first {
                $0.provider == item.provider && $0.window == item.window && $0.reset == cycle
            }
            if let previous, timestamp - previous.at < Self.sampleInterval { continue }
            samples.append(UsageSample(at: timestamp, provider: item.provider, window: item.window,
                                       pct: item.pct, reset: cycle))
            added += 1
        }
        guard added > 0 else {
            samples = old
            return 0
        }
        samples.sort { $0.at < $1.at }
        do {
            try persist()
        } catch {
            samples = old
            return 0
        }
        return added
    }

    public func forecast(provider: String, window: String, resetAt: Double, now: Double? = nil) -> Forecast {
        guard Self.providers.contains(provider), Self.windows.contains(window), resetAt.isFinite else {
            return Forecast(state: "unavailable")
        }
        let current = now ?? self.now()
        guard current.isFinite else { return Forecast(state: "unavailable") }
        let cycle = Self.resetCycle(resetAt)
        let cutoff = current - Self.forecastWindow
        lock.lock()
        var picked = samples.filter {
            $0.provider == provider && $0.window == window && $0.reset == cycle
                && cutoff <= $0.at && $0.at <= current
        }
        lock.unlock()
        guard !picked.isEmpty else { return Forecast(state: "unavailable") }
        picked.sort { $0.at < $1.at }
        let latest = picked[picked.count - 1]
        if resetAt <= latest.at { return Forecast(state: "unavailable") }
        let span = picked[picked.count - 1].at - picked[0].at
        let pcts = picked.map(\.pct)
        let movement = (pcts.max() ?? 0) - (pcts.min() ?? 0)
        if picked.count < 3 || span < Self.minForecastSpan || movement < Self.minForecastDelta {
            return Forecast(state: "collecting")
        }
        let origin = picked[0].at
        let xs = picked.map { $0.at - origin }
        let ys = pcts
        let meanX = xs.reduce(0, +) / Double(xs.count)
        let meanY = ys.reduce(0, +) / Double(ys.count)
        let denominator = xs.reduce(0) { $0 + ($1 - meanX) * ($1 - meanX) }
        if denominator <= 0 { return Forecast(state: "collecting") }
        var slope = 0.0
        for index in xs.indices {
            slope += (xs[index] - meanX) * (ys[index] - meanY)
        }
        slope /= denominator
        if !slope.isFinite || slope <= 0 { return Forecast(state: "unavailable") }
        let secondsLeft = resetAt - latest.at
        let gain = slope * secondsLeft
        let projected = latest.pct + gain
        if projected >= 100 {
            let exhaustsAt = PyRound.integer(latest.at + (100 - latest.pct) / slope)
            return Forecast(state: "exhausts", exhaustsAt: exhaustsAt,
                            offsetMinutes: PyRound.integer((Double(exhaustsAt) - resetAt) / 60))
        }
        let pace = gain > 0 ? (100 - latest.pct) / gain : nil
        let clamped = min(100, max(0, PyRound.integer(projected)))
        return Forecast(state: "at_reset", pctAtReset: clamped,
                        paceFactor: pace.map { PyRound.places($0, 1) })
    }

    public func deltaSince(provider: String, window: String, since: Double, resetAt: Double,
                           now: Double? = nil) -> Double? {
        guard Self.providers.contains(provider), Self.windows.contains(window),
              since.isFinite, resetAt.isFinite else { return nil }
        let current = now ?? self.now()
        guard current.isFinite, let length = Self.windowLength[window] else { return nil }
        let cycle = Self.resetCycle(resetAt)
        lock.lock()
        var picked = samples.filter {
            $0.provider == provider && $0.window == window && $0.reset == cycle && $0.at <= current
        }
        lock.unlock()
        guard !picked.isEmpty else { return nil }
        picked.sort { $0.at < $1.at }
        let latest = picked[picked.count - 1]
        if resetAt - length >= since {
            return PyRound.places(max(0, latest.pct), 1)
        }
        guard picked.count >= 2 else { return nil }
        let earlier = picked.filter { $0.at <= since }
        let baselineIndex = earlier.isEmpty ? 0 : picked.firstIndex { $0.at == earlier[earlier.count - 1].at && $0.pct == earlier[earlier.count - 1].pct } ?? 0
        if baselineIndex == picked.count - 1 { return nil }
        let delta = latest.pct - picked[baselineIndex].pct
        return delta < 0 ? nil : PyRound.places(delta, 1)
    }

    /// Unexpired OBS-39 evidence for `quotaRegressions`, sorted by `at`.
    /// The first time a later sample in a reset bucket is below an earlier one is the record.
    /// No such pair — including an empty history — is `[]`.
    public func quotaRegressions(now: Double? = nil) -> [QuotaRegression] {
        let current = now ?? self.now()
        guard current.isFinite else { return [] }
        lock.lock()
        let snapshot = samples
        lock.unlock()
        guard !snapshot.isEmpty else { return [] }

        var groups: [String: [UsageSample]] = [:]
        for sample in snapshot {
            guard sample.at <= current, sample.reset > current,
                  sample.at.isFinite, sample.pct.isFinite, sample.reset.isFinite,
                  let scope = Self.scopeForWindow[sample.window] else { continue }
            let key = "\(sample.provider)\u{0}\(scope)\u{0}\(sample.reset)"
            groups[key, default: []].append(sample)
        }

        var found: [QuotaRegression] = []
        for rows in groups.values {
            let ordered = rows.sorted { $0.at < $1.at }
            guard ordered.count >= 2,
                  let scope = Self.scopeForWindow[ordered[0].window],
                  let resetAt = Self.epoch(ordered[0].reset) else { continue }
            var previous = ordered[0]
            for sample in ordered.dropFirst() {
                if sample.pct < previous.pct {
                    guard let at = Self.epoch(sample.at) else { break }
                    found.append(QuotaRegression(
                        provider: sample.provider,
                        scope: scope,
                        livePct: PyRound.places(sample.pct, 1),
                        cachedPct: PyRound.places(previous.pct, 1),
                        resetAt: resetAt,
                        at: at
                    ))
                    break
                }
                previous = sample
            }
        }
        return found.sorted { lhs, rhs in
            if lhs.at != rhs.at { return lhs.at < rhs.at }
            if lhs.provider != rhs.provider { return lhs.provider < rhs.provider }
            if lhs.scope != rhs.scope { return lhs.scope < rhs.scope }
            return lhs.resetAt < rhs.resetAt
        }
    }

    static func resetCycle(_ resetAt: Double) -> Double {
        let quantum = resetQuantum
        return floor((resetAt + quantum / 2) / quantum) * quantum
    }

    /// Whole epoch seconds. A non-integer is absent, not zero.
    private static func epoch(_ value: Double) -> Int? {
        guard value.isFinite, value >= 0, value < Double(Int.max) else { return nil }
        let truncated = value.rounded(.towardZero)
        guard truncated == value else { return nil }
        return Int(truncated)
    }

    private func load() -> [UsageSample] {
        switch StateIO.read(path) {
        case .missing:
            return []
        case .notUTF8:
            StateFiles.quarantine(path, reason: "not UTF-8")
            return []
        case let .unreadable(name):
            loadError = name
            return []
        case let .data(data):
            guard let value = StateIO.parseObject(data) else {
                StateFiles.quarantine(path, reason: "invalid JSON at byte 0")
                return []
            }
            guard let object = value.object, object["v"]?.int == 1, let rows = object["samples"]?.array else {
                StateFiles.quarantine(path, reason: "not a {v: 1, samples: [...]} file")
                return []
            }
            var kept = rows.compactMap(Self.sample)
            kept.sort { $0.at < $1.at }
            let cutoff = now() - Self.retention
            return kept.filter { $0.at >= cutoff }
        }
    }

    private static func sample(_ value: StrictJSON.Value) -> UsageSample? {
        guard let object = value.object, Set(object.keys) == sampleKeys,
              let at = object["at"]?.number, let provider = object["provider"]?.string,
              let window = object["window"]?.string, let pct = object["pct"]?.number,
              let reset = object["reset"]?.number else { return nil }
        guard providers.contains(provider), windows.contains(window),
              at.isFinite, pct.isFinite, (0...100).contains(pct), reset.isFinite else { return nil }
        return UsageSample(at: at, provider: provider, window: window, pct: pct, reset: reset)
    }

    private func persist() throws {
        if let loadError {
            throw StatePersistenceError("\(path.lastPathComponent) was unreadable at startup (\(loadError)); refusing to overwrite it")
        }
        let rows = samples.map { sample -> JSONValue in
            .object([
                ("at", JSONWire.number(sample.at, forceFloat: false)),
                ("provider", .string(sample.provider)),
                ("window", .string(sample.window)),
                ("pct", .double(sample.pct)),
                ("reset", JSONWire.number(sample.reset, forceFloat: false)),
            ])
        }
        try StateFiles.atomicWrite(JSONWire.encode(.object([("v", .int(1)), ("samples", .array(rows))])), to: path)
        chmod(path.path, 0o600)
    }
}
