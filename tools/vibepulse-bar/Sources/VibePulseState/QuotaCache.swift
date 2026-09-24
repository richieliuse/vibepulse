import Foundation
import VibePulseSupport

public struct CachedQuota: Equatable, Sendable {
    public var provider: String
    public var scope: String
    public var identity: String
    public var pct: Double
    public var resetAt: Int
    public var observedAt: Int
    public var label: String?

    public init(provider: String, scope: String, identity: String, pct: Double,
                resetAt: Int, observedAt: Int, label: String? = nil) {
        self.provider = provider
        self.scope = scope
        self.identity = identity
        self.pct = pct
        self.resetAt = resetAt
        self.observedAt = observedAt
        self.label = label
    }
}

public final class QuotaCache: @unchecked Sendable {
    public let path: URL
    private let now: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var records: [Key: CachedQuota] = [:]
    private var readRecords: [CachedQuota] = []

    private typealias Key = String

    private static let providers: Set<String> = ["claude", "codex"]
    private static let scopes: Set<String> = ["general_session", "general_weekly", "model_weekly"]
    private static let recordKeys: Set<String> = [
        "provider", "scope", "identity", "pct", "reset_at", "observed_at", "label",
    ]

    public init(path: URL, now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.path = path
        self.now = now
        self.records = load()
        self.readRecords = Array(records.values)
    }

    public func put(_ record: CachedQuota) -> Bool {
        guard Self.valid(record) else { return false }
        lock.lock()
        defer { lock.unlock() }
        let key = Self.key(record)
        if let previous = records[key], record.observedAt < previous.observedAt {
            return false
        }
        switch StateIO.read(path) {
        case .missing: break
        case .data: break
        case .notUTF8, .unreadable: return false
        }
        let old = records
        records[key] = record
        let snapshot = Array(records.values)
        do {
            try persist(snapshot)
        } catch {
            records = old
            return false
        }
        readRecords = snapshot
        return true
    }

    public func latest(provider: String, scope: String, now: TimeInterval? = nil) -> CachedQuota? {
        guard Self.providers.contains(provider), Self.scopes.contains(scope) else { return nil }
        let current = now ?? self.now()
        guard current.isFinite else { return nil }
        lock.lock()
        let snapshot = readRecords
        lock.unlock()
        let candidates = snapshot.filter {
            $0.provider == provider && $0.scope == scope && Double($0.resetAt) > current
        }
        return candidates.max { lhs, rhs in
            if lhs.observedAt != rhs.observedAt { return lhs.observedAt < rhs.observedAt }
            return lhs.identity < rhs.identity
        }
    }

    static func valid(_ record: CachedQuota) -> Bool {
        providers.contains(record.provider) && scopes.contains(record.scope)
            && identityOK(record.identity) && record.pct.isFinite && record.pct >= 0 && record.pct <= 100
            && record.resetAt >= 0 && record.observedAt >= 0 && labelOK(record.label)
    }

    private func load() -> [Key: CachedQuota] {
        switch StateIO.read(path) {
        case .missing, .unreadable:
            return [:]
        case .notUTF8:
            StateFiles.quarantine(path, reason: "not UTF-8")
            return [:]
        case let .data(data):
            guard let value = StateIO.parseObject(data) else {
                StateFiles.quarantine(path, reason: "invalid JSON at byte 0")
                return [:]
            }
            guard let object = value.object, Set(object.keys) == ["v", "records"],
                  object["v"]?.int == 1, let rows = object["records"]?.array else {
                StateFiles.quarantine(path, reason: "not a {v: 1, records: [...]} file")
                return [:]
            }
            let current = now()
            let prune = current.isFinite
            var kept: [Key: CachedQuota] = [:]
            for row in rows {
                guard let record = Self.from(row) else { continue }
                if prune && Double(record.resetAt) <= current { continue }
                let key = Self.key(record)
                if let previous = kept[key], record.observedAt <= previous.observedAt { continue }
                kept[key] = record
            }
            return kept
        }
    }

    private static func from(_ value: StrictJSON.Value) -> CachedQuota? {
        guard let object = value.object, Set(object.keys) == recordKeys,
              let provider = object["provider"]?.string, let scope = object["scope"]?.string,
              let identity = object["identity"]?.string, let pct = object["pct"]?.number,
              let resetAt = object["reset_at"]?.int, let observedAt = object["observed_at"]?.int else {
            return nil
        }
        let label: String?
        switch object["label"] {
        case .null, .none: label = nil
        case let .string(text): label = text
        default: return nil
        }
        let record = CachedQuota(provider: provider, scope: scope, identity: identity, pct: pct,
                                 resetAt: resetAt, observedAt: observedAt, label: label)
        return valid(record) ? record : nil
    }

    private func persist(_ snapshot: [CachedQuota]) throws {
        let sorted = snapshot.sorted {
            ($0.provider, $0.scope, $0.identity) < ($1.provider, $1.scope, $1.identity)
        }
        let rows = sorted.map { record -> JSONValue in
            .object([
                ("provider", .string(record.provider)),
                ("scope", .string(record.scope)),
                ("identity", .string(record.identity)),
                ("pct", .double(record.pct)),
                ("reset_at", .int(record.resetAt)),
                ("observed_at", .int(record.observedAt)),
                ("label", record.label.map(JSONValue.string) ?? .null),
            ])
        }
        let payload = JSONValue.object([("v", .int(1)), ("records", .array(rows))])
        try StateFiles.atomicWrite(JSONWire.encode(payload), to: path)
    }

    private static func key(_ record: CachedQuota) -> Key {
        "\(record.provider)\u{0}\(record.scope)\u{0}\(record.identity)"
    }

    private static func identityOK(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        guard (1...128).contains(scalars.count) else { return false }
        return scalars.allSatisfy { (0x20...0x7E).contains($0.value) }
    }

    static func labelOK(_ value: String?) -> Bool {
        guard let value else { return true }
        let scalars = Array(value.unicodeScalars)
        guard scalars.count <= 128 else { return false }
        return scalars.allSatisfy(isPythonPrintable)
    }

    private static func isPythonPrintable(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value == 0x20 { return true }
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned,
             .spaceSeparator, .lineSeparator, .paragraphSeparator:
            return false
        default:
            return true
        }
    }
}
