import Darwin
import Foundation

public struct CodexAppServerRead: Equatable {
    public var limits: CodexQuota
    public var sent: [String]

    public init(limits: CodexQuota, sent: [String]) {
        self.limits = limits
        self.sent = sent
    }
}

public struct CodexMonthTotals: Equatable {
    public var usd: Double
    public var pricedTokens: Int
    public var unpricedTokens: Int

    public init(usd: Double = 0, pricedTokens: Int = 0, unpricedTokens: Int = 0) {
        self.usd = usd
        self.pricedTokens = pricedTokens
        self.unpricedTokens = unpricedTokens
    }
}

public typealias CodexUsagePrice = (_ model: String?, _ usage: CodexRolloutUsage) -> (usd: Double, unpricedTokens: Int)

/// Codex quota from an injected app-server transcript, plus the newest rollout tails.
/// `monthValue` prices `last_token_usage` through an injected callback. The default returns zeros.
public final class CodexLimitsSource {
    public static let scanFileLimit = 20
    public static let scanByteLimit = 1_048_576
    public static let appServerTimeout: TimeInterval = 15

    public static func zeroPrice(_ model: String?, _ usage: CodexRolloutUsage) -> (usd: Double, unpricedTokens: Int) {
        (0, 0)
    }

    private var cache: [String: CachedRollout] = [:]
    private var cacheOrder: [String] = []

    public init() {}

    /// Speak the initialize / initialized / `account/rateLimits/read` handshake against `lines`.
    /// `lines` ends at EOF. Nothing is spawned.
    public func readAppServer<Lines: Sequence>(lines: Lines, now: TimeInterval) -> CodexAppServerRead where Lines.Element == String {
        var sent: [String] = []
        func send(_ object: [String: Any]) {
            sent.append(Self.encode(object))
        }
        send([
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": ["name": "vibepulse", "version": "1"],
                "capabilities": [String: String](),
            ] as [String: Any],
        ])
        var requested = false
        for line in lines {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let message = JSON.object(from: Data(text.utf8)),
                  let id = Self.rpcID(message) else { continue }
            if id == 1 && !requested {
                send(["method": "initialized", "params": [String: String]()])
                send(["id": 2, "method": "account/rateLimits/read"])
                requested = true
            } else if id == 2 {
                let observed = Int(exactly: now.rounded(.towardZero)) ?? 0
                guard let result = JSON.dictionary(message["result"]), let data = Self.encodeData(result) else {
                    return CodexAppServerRead(limits: CodexQuota(), sent: sent)
                }
                let limits = CodexRateLimits.parseResponse(data, observedAt: observed, now: now)
                return CodexAppServerRead(limits: limits, sent: sent)
            }
        }
        return CodexAppServerRead(limits: CodexQuota(), sent: sent)
    }

    /// Newest `rollout-*.jsonl` files, at most 20, each tail capped at 1 MiB.
    /// The newest general observation wins; a named quota does not count as general.
    public func scan(sessionsDirectory: URL, now: TimeInterval, fileLimit: Int = CodexLimitsSource.scanFileLimit, maxBytes: Int = CodexLimitsSource.scanByteLimit) -> CodexQuota {
        guard let files = Self.rolloutURLs(under: sessionsDirectory) else { return CodexQuota() }
        let budget = min(max(maxBytes, 0), Self.scanByteLimit)
        let limit = max(fileLimit, 0)
        var ranked: [(url: URL, mtime: TimeInterval)] = []
        for url in files {
            guard let stamp = Self.stamp(url) else { return CodexQuota() }
            ranked.append((url, stamp.mtime))
        }
        ranked.sort { $0.mtime > $1.mtime }
        var bestWeek: WeekPick?
        var bestSession: SessionPick?
        for item in ranked.prefix(limit) {
            let observations = readObservations(at: item.url, now: now, maxBytes: budget)
            if let week = observations.week, let pct = week.weekPct, let reset = week.weekResetAt, let window = week.weekWindowMinutes {
                if bestWeek == nil || week.observedAt > bestWeek!.observedAt {
                    bestWeek = WeekPick(pct: pct, resetAt: reset, observedAt: week.observedAt, window: window, limitID: week.limitID)
                }
            }
            if let session = observations.session, let pct = session.sessionPct, let reset = session.sessionResetMin, let window = session.sessionWindowMinutes {
                if bestSession == nil || session.observedAt > bestSession!.observedAt {
                    bestSession = SessionPick(pct: pct, resetMin: reset, window: window, observedAt: session.observedAt)
                }
            }
        }
        var out = CodexQuota()
        if let week = bestWeek {
            out.codexWeekPct = week.pct
            out.codexWeekResetAt = week.resetAt
            out.codexWeekObservedAt = week.observedAt
            out.codexWeekIdentity = QuotaIdentity.make(provider: "codex", scope: "general_weekly", raw: week.limitID)
            out.codexWeekStale = false
            out.codexWeekWindowMinutes = week.window
        }
        if let session = bestSession {
            out.codexSessionPct = session.pct
            out.codexSessionResetMin = session.resetMin
            out.codexSessionWindowMinutes = session.window
        }
        return out
    }

    /// Month-to-date Codex value. A missing directory is `(0, 0, 0)`.
    /// Files that share a `session_id` count once, from the rollout with the most tokens.
    public func monthValue(sessionsDirectory: URL, now: Date = Date(), price: @escaping CodexUsagePrice = CodexLimitsSource.zeroPrice) -> CodexMonthTotals {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sessionsDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return CodexMonthTotals()
        }
        guard let files = Self.rolloutURLs(under: sessionsDirectory) else { return CodexMonthTotals() }
        let bounds = Self.monthBounds(now)
        var live = Set<String>()
        for url in files {
            guard let stamp = Self.stamp(url) else { continue }
            if Date(timeIntervalSince1970: stamp.mtime) < bounds.start { continue }
            let key = url.path
            live.insert(key)
            let cached = cache[key]
            if let cached, cached.mtimeSec == stamp.mtimeSec, cached.mtimeNsec == stamp.mtimeNsec,
               cached.size == stamp.size, cached.dev == stamp.dev, cached.ino == stamp.ino {
                continue
            }
            let canAppend = cached != nil && cached?.month == bounds.key && cached?.dev == stamp.dev
                && cached?.ino == stamp.ino && stamp.size > (cached?.size ?? 0)
            if canAppend, var cached {
                let parsed = parseRollout(url, monthStart: bounds.start, offset: cached.offset, model: cached.model, sessionID: cached.sessionID, price: price)
                cached.records.append(contentsOf: parsed.records)
                cached.mtimeSec = stamp.mtimeSec
                cached.mtimeNsec = stamp.mtimeNsec
                cached.size = stamp.size
                cached.offset = parsed.offset
                cached.model = parsed.model
                cached.sessionID = parsed.sessionID
                cache[key] = cached
            } else {
                let parsed = parseRollout(url, monthStart: bounds.start, offset: 0, model: nil, sessionID: nil, price: price)
                if cache[key] == nil { cacheOrder.append(key) }
                cache[key] = CachedRollout(
                    mtimeSec: stamp.mtimeSec, mtimeNsec: stamp.mtimeNsec, size: stamp.size,
                    dev: stamp.dev, ino: stamp.ino, offset: parsed.offset, month: bounds.key,
                    model: parsed.model, sessionID: parsed.sessionID, records: parsed.records
                )
            }
        }
        cacheOrder.removeAll { !live.contains($0) }
        for stale in Set(cache.keys).subtracting(live) { cache.removeValue(forKey: stale) }

        var best: [Group: Pick] = [:]
        for path in cacheOrder {
            guard let entry = cache[path] else { continue }
            var usd = 0.0
            var priced = 0
            var unpriced = 0
            for record in entry.records {
                usd += record.usd
                priced += record.priced
                unpriced += record.unpriced
            }
            let tokens = priced + unpriced
            let group: Group = entry.sessionID.map { .session($0) } ?? .file(path)
            if let current = best[group] {
                if tokens > current.tokens {
                    best[group] = Pick(tokens: tokens, usd: usd, priced: priced, unpriced: unpriced)
                }
            } else {
                best[group] = Pick(tokens: tokens, usd: usd, priced: priced, unpriced: unpriced)
            }
        }
        var totalUSD = 0.0
        var totalPriced = 0
        var totalUnpriced = 0
        for pick in best.values {
            totalUSD += pick.usd
            totalPriced += pick.priced
            totalUnpriced += pick.unpriced
        }
        return CodexMonthTotals(usd: totalUSD, pricedTokens: totalPriced, unpricedTokens: totalUnpriced)
    }

    private func readObservations(at url: URL, now: TimeInterval, maxBytes: Int) -> (week: CodexLineHit?, session: CodexLineHit?) {
        guard maxBytes > 0, let handle = try? FileHandle(forReadingFrom: url) else { return (nil, nil) }
        defer { try? handle.close() }
        let end: UInt64
        do {
            end = try handle.seekToEnd()
        } catch {
            return (nil, nil)
        }
        guard end <= UInt64(Int.max) else { return (nil, nil) }
        var position = Int(end)
        var fragment = Data()
        var remaining = maxBytes
        var week: CodexLineHit?
        var session: CodexLineHit?
        func consider(_ raw: Data) {
            guard week == nil || session == nil else { return }
            guard raw.range(of: Self.rateLimitsMarker) != nil else { return }
            guard let hit = CodexRollout.lineHit(raw, now: now) else { return }
            if week == nil, hit.weekPct != nil { week = hit }
            if session == nil, hit.sessionPct != nil { session = hit }
        }
        do {
            while position > 0 && remaining > 0 && (week == nil || session == nil) {
                let readSize = min(64 * 1024, position, remaining)
                position -= readSize
                remaining -= readSize
                try handle.seek(toOffset: UInt64(position))
                let chunk = try Self.readExact(handle, count: readSize)
                let parts = Self.splitNewlines(chunk + fragment)
                fragment = parts.first ?? Data()
                for raw in parts.dropFirst().reversed() {
                    consider(raw)
                    if week != nil && session != nil { return (week, session) }
                }
            }
        } catch {
            return (week, session)
        }
        if position == 0 { consider(fragment) }
        return (week, session)
    }

    private func parseRollout(_ url: URL, monthStart: Date, offset: Int, model incomingModel: String?, sessionID incomingSession: String?, price: CodexUsagePrice) -> (records: [UsageRecord], offset: Int, model: String?, sessionID: String?) {
        guard let data = try? Data(contentsOf: url) else { return ([], offset, incomingModel, incomingSession) }
        let bytes = [UInt8](data)
        guard offset >= 0, offset <= bytes.count else { return ([], offset, incomingModel, incomingSession) }
        var records: [UsageRecord] = []
        var model = incomingModel
        var sessionID = incomingSession
        var index = offset
        var lineStart = offset
        var parsedUntil = offset
        while index < bytes.count {
            if bytes[index] == 0x0A {
                consume(Data(bytes[lineStart..<index]), monthStart: monthStart, price: price, model: &model, sessionID: &sessionID, records: &records)
                index += 1
                lineStart = index
                parsedUntil = lineStart
                continue
            }
            index += 1
        }
        if lineStart < bytes.count { parsedUntil = lineStart }
        return (records, parsedUntil, model, sessionID)
    }

    private func consume(_ line: Data, monthStart: Date, price: CodexUsagePrice, model: inout String?, sessionID: inout String?, records: inout [UsageRecord]) {
        guard JSON.object(from: line) != nil else { return }
        if sessionID == nil, let found = CodexRollout.sessionID(in: line) {
            sessionID = found
            return
        }
        if let turn = CodexRollout.turnModel(in: line) {
            model = turn
            return
        }
        guard let usage = CodexRollout.lastTokenUsage(in: line),
              let object = JSON.object(from: line),
              let raw = JSON.string(object["timestamp"]),
              let instant = Instants.parse(raw, naiveZone: .current),
              Date(timeIntervalSince1970: instant) >= monthStart else { return }
        let (usd, unpriced) = price(model, usage)
        let priced = unpriced != 0 ? 0 : Self.counted(usage)
        if usd != 0 || unpriced != 0 || priced != 0 {
            records.append(UsageRecord(usd: usd, priced: priced, unpriced: unpriced))
        }
    }

    private static func counted(_ usage: CodexRolloutUsage) -> Int {
        func one(_ value: Int?) -> Int {
            guard let value, value > 0 else { return 0 }
            return value
        }
        return one(usage.inputTokens) + one(usage.outputTokens) + one(usage.cacheWriteInputTokens)
    }

    private static func rolloutURLs(under root: URL) -> [URL]? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { return [] }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in true }) else {
            return nil
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
                files.append(url)
            }
        }
        return files
    }

    private static func monthBounds(_ now: Date) -> (start: Date, key: String) {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.year, .month], from: now)
        var startParts = DateComponents()
        startParts.year = parts.year
        startParts.month = parts.month
        startParts.day = 1
        startParts.hour = 0
        startParts.minute = 0
        startParts.second = 0
        let start = calendar.date(from: startParts) ?? now
        return (start, String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0))
    }

    private static func stamp(_ url: URL) -> Stamp? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return Stamp(
            mtimeSec: Int64(info.st_mtimespec.tv_sec),
            mtimeNsec: Int64(info.st_mtimespec.tv_nsec),
            size: Int64(info.st_size),
            dev: UInt64(info.st_dev),
            ino: UInt64(info.st_ino)
        )
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = encodeData(object) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func encodeData(_ object: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object)
    }

    private static func rpcID(_ object: [String: Any]) -> Int? {
        guard let number = JSON.finite(object["id"]) else { return nil }
        if number == 1 { return 1 }
        if number == 2 { return 2 }
        return nil
    }

    private static func readExact(_ handle: FileHandle, count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        return data
    }

    private static func splitNewlines(_ data: Data) -> [Data] {
        var parts: [Data] = []
        var start = data.startIndex
        var index = data.startIndex
        while index < data.endIndex {
            if data[index] == 0x0A {
                parts.append(data.subdata(in: start..<index))
                index = data.index(after: index)
                start = index
                continue
            }
            index = data.index(after: index)
        }
        parts.append(data.subdata(in: start..<data.endIndex))
        return parts
    }

    private static let rateLimitsMarker = Data("\"rate_limits\"".utf8)

    private struct Stamp {
        var mtimeSec: Int64
        var mtimeNsec: Int64
        var size: Int64
        var dev: UInt64
        var ino: UInt64
        var mtime: TimeInterval { TimeInterval(mtimeSec) + TimeInterval(mtimeNsec) / 1e9 }
    }

    private struct WeekPick {
        var pct: Double
        var resetAt: Int
        var observedAt: Int
        var window: Double
        var limitID: String?
    }

    private struct SessionPick {
        var pct: Double
        var resetMin: Int
        var window: Double
        var observedAt: Int
    }

    private struct UsageRecord {
        var usd: Double
        var priced: Int
        var unpriced: Int
    }

    private struct CachedRollout {
        var mtimeSec: Int64
        var mtimeNsec: Int64
        var size: Int64
        var dev: UInt64
        var ino: UInt64
        var offset: Int
        var month: String
        var model: String?
        var sessionID: String?
        var records: [UsageRecord]
    }

    private struct Pick {
        var tokens: Int
        var usd: Double
        var priced: Int
        var unpriced: Int
    }

    private enum Group: Hashable {
        case session(String)
        case file(String)
    }
}
