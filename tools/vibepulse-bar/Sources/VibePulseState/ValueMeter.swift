import Foundation
import VibePulseSupport

public struct ValuePayload: Equatable {
    public let keys: [String]
    public let fields: [String: StrictJSON.Value]
    public subscript(_ key: String) -> StrictJSON.Value? { fields[key] }
}

public struct PriceTable: Sendable {
    private struct Model {
        var accounting: String
        var spec: [String: StrictJSON.Value]
        var rates: [String: StrictJSON.Value]
    }

    private let sourceGenerated: String?
    private let plans: [String: [String: StrictJSON.Value]]
    private let models: [String: Model]

    public init(document: StrictJSON.Value) throws {
        let object = document.object ?? [:]
        if let source = object["source"]?.object, let generated = source["generated"]?.string {
            sourceGenerated = generated
        } else {
            sourceGenerated = nil
        }
        var planIndex: [String: [String: StrictJSON.Value]] = [:]
        if let planObject = object["plans"]?.object {
            for (provider, value) in planObject {
                if let rates = value.object { planIndex[provider] = rates }
            }
        }
        plans = planIndex
        var index: [String: Model] = [:]
        let providers = object["providers"]?.object ?? [:]
        for (provider, value) in providers {
            guard let spec = value.object else { continue }
            guard let accounting = spec["accounting"]?.string,
                  accounting == "cache_excluded_input" || accounting == "cache_included_input" else {
                throw PriceTableError.unknownAccounting(provider: provider, accounting: spec["accounting"])
            }
            let modelObject = spec["models"]?.object ?? [:]
            for (model, rates) in modelObject {
                guard let rates = rates.object else { continue }
                index[model] = Model(accounting: accounting, spec: spec, rates: rates)
            }
        }
        models = index
    }

    public static func load(from url: URL, override: URL? = nil) throws -> PriceTable {
        let base = try Data(contentsOf: url)
        guard var document = StateIO.parseObject(base) else {
            throw PriceTableError.malformed
        }
        if let override {
            let extraData = try Data(contentsOf: override)
            guard let extra = StateIO.parseObject(extraData) else { throw PriceTableError.malformed }
            document = merge(document, extra)
        }
        return try PriceTable(document: document)
    }

    public func knows(_ model: String?) -> Bool {
        guard let model else { return false }
        return models[model] != nil
    }

    public func asOf() -> String? { sourceGenerated }

    public func price(model: String?, usage: StrictJSON.Value) -> (usd: Double, unpricedTokens: Int) {
        guard let usage = usage.object else { return (0, 0) }
        guard let model, let entry = models[model] else {
            return (0, Self.countable(usage))
        }
        let inputRate = Self.number(entry.rates["input"]) ?? 0
        let outputRate = Self.number(entry.rates["output"]) ?? 0
        let priced: (Double, Int)
        if entry.accounting == "cache_excluded_input" {
            priced = priceExcluded(usage, entry, inputRate, outputRate)
        } else {
            priced = priceIncluded(usage, entry, inputRate, outputRate)
        }
        if priced.1 <= 0 { return (0, 0) }
        return (priced.0 * tier(usage, entry.spec), 0)
    }

    public func planCost(provider: String, plan: String?, override: StrictJSON.Value? = nil) -> (cost: Double?, source: String) {
        if let amount = Self.number(override), amount > 0 { return (amount, "configured") }
        if let plan, let amount = Self.number(plans[provider]?[plan]), amount > 0 {
            return (amount, "default")
        }
        return (nil, "unknown")
    }

    private func priceExcluded(_ usage: [String: StrictJSON.Value], _ entry: Model,
                               _ inputRate: Double, _ outputRate: Double) -> (Double, Int) {
        let fresh = Self.count(usage["input_tokens"])
        let out = Self.count(usage["output_tokens"])
        let read = Self.count(usage["cache_read_input_tokens"])
        let split = Self.cacheWriteSplit(usage)
        let write5 = cacheRate(entry, "cache_write_5m", "cache_write_5m_multiplier", inputRate)
        let write1 = cacheRate(entry, "cache_write_1h", "cache_write_1h_multiplier", inputRate)
        let readRate = cacheRate(entry, "cache_read", "cache_read_multiplier", inputRate)
        let usd = (Double(fresh) * inputRate + Double(out) * outputRate + Double(split.0) * write5
            + Double(split.1) * write1 + Double(read) * readRate) / 1_000_000
        return (usd, fresh + out + read + split.0 + split.1)
    }

    private func priceIncluded(_ usage: [String: StrictJSON.Value], _ entry: Model,
                               _ inputRate: Double, _ outputRate: Double) -> (Double, Int) {
        let totalIn = Self.count(usage["input_tokens"])
        let cached = min(Self.count(usage["cached_input_tokens"]), totalIn)
        let fresh = totalIn - cached
        let out = Self.count(usage["output_tokens"])
        let write = Self.count(usage["cache_write_input_tokens"])
        let cachedRate = cacheRate(entry, "cache_read", "cache_read_multiplier", inputRate)
        let writeRate = cacheRate(entry, "cache_write_5m", "cache_write_5m_multiplier", inputRate)
        let usd = (Double(fresh) * inputRate + Double(cached) * cachedRate + Double(write) * writeRate
            + Double(out) * outputRate) / 1_000_000
        return (usd, totalIn + out + write)
    }

    private func cacheRate(_ entry: Model, _ rateKey: String, _ multiplierKey: String, _ inputRate: Double) -> Double {
        if let exact = Self.number(entry.rates[rateKey]) { return exact }
        return inputRate * (Self.number(entry.spec[multiplierKey]) ?? 0)
    }

    private func tier(_ usage: [String: StrictJSON.Value], _ spec: [String: StrictJSON.Value]) -> Double {
        guard let table = spec["tier_multipliers"]?.object, let name = usage["service_tier"]?.string else { return 1 }
        guard let amount = Self.number(table[name]), amount != 0 else { return 1 }
        return amount
    }

    static func countable(_ usage: [String: StrictJSON.Value]) -> Int {
        count(usage["input_tokens"]) + count(usage["output_tokens"]) + count(usage["cache_read_input_tokens"])
            + count(usage["cache_creation_input_tokens"]) + count(usage["cache_write_input_tokens"])
    }

    static func cacheWriteSplit(_ usage: [String: StrictJSON.Value]) -> (Int, Int) {
        if let detail = usage["cache_creation"]?.object {
            let five = count(detail["ephemeral_5m_input_tokens"])
            let hour = count(detail["ephemeral_1h_input_tokens"])
            if five != 0 || hour != 0 { return (five, hour) }
        }
        return (count(usage["cache_creation_input_tokens"]), 0)
    }

    static func number(_ value: StrictJSON.Value?) -> Double? {
        guard let number = value?.number, number.isFinite, number >= 0 else { return nil }
        return number
    }

    static func count(_ value: StrictJSON.Value?) -> Int {
        guard let number = number(value), number < Double(Int.max) else { return 0 }
        return Int(number)
    }

    private static func merge(_ base: StrictJSON.Value, _ extra: StrictJSON.Value) -> StrictJSON.Value {
        guard let baseObject = base.object, let extraObject = extra.object else { return extra }
        var merged = baseObject
        for (key, value) in extraObject {
            if let child = merged[key] {
                merged[key] = merge(child, value)
            } else {
                merged[key] = value
            }
        }
        return .object(merged)
    }
}

public enum PriceTableError: Error, Equatable {
    case malformed
    case unknownAccounting(provider: String, accounting: StrictJSON.Value?)
}

public struct PlanCostError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

/// `--plan PROVIDER=USD`, with `--plan-cost-usd` as a legacy Claude override.
/// Later entries win. There is no provider allowlist.
public func parsePlanCosts(entries: [String], legacyClaude: Double? = nil) throws -> [String: Double] {
    var costs: [String: Double] = [:]
    if let legacyClaude {
        if !legacyClaude.isFinite || legacyClaude <= 0 {
            throw PlanCostError("--plan-cost-usd must be a positive number, got \(pythonNumberRepr(legacyClaude))")
        }
        costs["claude"] = legacyClaude
    }
    for entry in entries {
        let providerRaw: String
        let raw: String
        let separated: Bool
        if let index = entry.firstIndex(of: "=") {
            providerRaw = String(entry[..<index])
            raw = String(entry[entry.index(after: index)...])
            separated = true
        } else {
            providerRaw = entry
            raw = ""
            separated = false
        }
        let provider = providerRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !separated || provider.isEmpty {
            throw PlanCostError("--plan expects PROVIDER=USD, got \(pythonStringRepr(entry)) (for example: --plan claude=200)")
        }
        guard let amount = pythonFloat(raw), amount.isFinite, amount > 0 else {
            throw PlanCostError("--plan \(provider) needs a positive monthly cost in USD, got \(pythonStringRepr(raw))")
        }
        costs[provider] = amount
    }
    return costs
}

/// Python `float()`: surrounding whitespace, `1e2`, and a single `_` between digits.
private func pythonFloat(_ raw: String) -> Double? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }
    var cleaned = ""
    let chars = Array(trimmed)
    for index in chars.indices {
        let char = chars[index]
        if char == "_" {
            if index == chars.startIndex || index == chars.index(before: chars.endIndex) { return nil }
            let previous = chars[chars.index(before: index)]
            let next = chars[chars.index(after: index)]
            if !isASCIIDigit(previous) || !isASCIIDigit(next) { return nil }
            continue
        }
        cleaned.append(char)
    }
    let lower = cleaned.lowercased()
    switch lower {
    case "inf", "+inf", "infinity", "+infinity": return .infinity
    case "-inf", "-infinity": return -.infinity
    case "nan", "+nan", "-nan": return .nan
    default: return Double(cleaned)
    }
}

private func isASCIIDigit(_ char: Character) -> Bool {
    char >= "0" && char <= "9"
}

private func pythonNumberRepr(_ value: Double) -> String {
    if value.isNaN { return "nan" }
    if value == .infinity { return "inf" }
    if value == -.infinity { return "-inf" }
    return String(value)
}

private func pythonStringRepr(_ text: String) -> String {
    var out = "'"
    for scalar in text.unicodeScalars {
        switch scalar.value {
        case 0x5C: out += "\\\\"
        case 0x27: out += "\\'"
        case 0x0A: out += "\\n"
        case 0x0D: out += "\\r"
        case 0x09: out += "\\t"
        case 0x00...0x1F, 0x7F: out += String(format: "\\x%02x", scalar.value)
        default: out.unicodeScalars.append(scalar)
        }
    }
    out += "'"
    return out
}

public func buildPayload(valueUSD: Double, unpricedTokens: Int, pricedTokens: Int,
                         claudePlan: String? = nil, codexPlan: String? = nil,
                         planCosts: [String: StrictJSON.Value] = [:], table: PriceTable,
                         claudeUSD: Double? = nil, codexUSD: Double? = nil) -> ValuePayload {
    let total = pricedTokens + unpricedTokens
    let share = total == 0 ? 0 : Double(unpricedTokens) / Double(total)
    let claude = table.planCost(provider: "claude", plan: claudePlan, override: planCosts["claude"])
    let codex = table.planCost(provider: "codex", plan: codexPlan, override: planCosts["codex"])
    let pairs: [(Double?, Double?, String)] = [
        (claudeUSD, claude.cost, claude.source),
        (codexUSD, codex.cost, codex.source),
    ]
    let counted = pairs.compactMap { spent, cost, _ -> (Double, Double)? in
        guard let spent, spent > 0, let cost else { return nil }
        return (spent, cost)
    }
    let uncounted = pairs.reduce(0.0) { partial, item in
        guard let spent = item.0, spent > 0, item.1 == nil else { return partial }
        return partial + spent
    }
    let knownSplit = claudeUSD != nil || codexUSD != nil
    var value = valueUSD
    let planUSD: Double?
    var sources: [String]
    if !knownSplit {
        let costs = [claude.cost, codex.cost].compactMap { $0 }
        planUSD = costs.isEmpty ? nil : costs.reduce(0, +)
        sources = [claude.source, codex.source].filter { $0 != "unknown" }
    } else if !counted.isEmpty {
        value = counted.reduce(0) { $0 + $1.0 }
        planUSD = counted.reduce(0) { $0 + $1.1 }
        sources = []
    } else {
        planUSD = nil
        sources = []
    }
    if knownSplit {
        sources = pairs.compactMap { spent, cost, source in
            guard let spent, spent > 0, cost != nil else { return nil }
            return source
        }
    }
    let costSource: String
    if !sources.isEmpty && sources.allSatisfy({ $0 == "configured" }) {
        costSource = "configured"
    } else if !sources.isEmpty {
        costSource = "default"
    } else {
        costSource = "unknown"
    }
    var keys = ["value_usd", "plan_usd", "cost_source", "basis", "prices_as_of", "unpriced_token_share"]
    var fields: [String: StrictJSON.Value] = [
        "value_usd": .double(PyRound.places(value, 2)),
        "plan_usd": planUSD.map { .double($0) } ?? .null,
        "cost_source": .string(costSource),
        "basis": .string("list API prices"),
        "prices_as_of": table.asOf().map { .string($0) } ?? .null,
        "unpriced_token_share": .double(PyRound.places(share, 4)),
    ]
    if uncounted > 0 {
        keys.append("undeclared_usd")
        fields["undeclared_usd"] = .double(PyRound.places(uncounted, 2))
    }
    for (name, spent, cost) in [("claude", claudeUSD, claude.cost), ("codex", codexUSD, codex.cost)] {
        guard let spent, spent > 0 else { continue }
        keys.append("\(name)_usd")
        fields["\(name)_usd"] = .double(PyRound.places(spent, 2))
        if let cost {
            keys.append("\(name)_plan_usd")
            fields["\(name)_plan_usd"] = .double(cost)
        }
    }
    keys.append("state")
    keys.append("multiple")
    if share > 0.02 {
        fields["state"] = .string("partial")
        fields["multiple"] = .null
    } else if planUSD == nil {
        fields["state"] = .string("no_plan_cost")
        fields["multiple"] = .null
    } else {
        fields["state"] = .string("ok")
        fields["multiple"] = .double(PyRound.places(value / planUSD!, 2))
    }
    return ValuePayload(keys: keys, fields: fields)
}
