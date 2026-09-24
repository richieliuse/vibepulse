import Darwin
import Foundation

public struct ClaudeUsage: Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationInputTokens: Int
    public var cacheReadInputTokens: Int

    public init(inputTokens: Int, outputTokens: Int, cacheCreationInputTokens: Int, cacheReadInputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }

    public var total: Int { inputTokens + outputTokens + cacheCreationInputTokens + cacheReadInputTokens }
}

public typealias ClaudePrice = (_ model: String?, _ usage: ClaudeUsage) -> (usd: Double, unpricedTokens: Int)

public enum TranscriptField: Equatable {
    case int(Int)
    case bool(Bool)
}

public struct TranscriptScan: Equatable {
    public var dayTokens: Int
    public var dayTokensPerHour: Int
    public var daySessions: Int
    public var monthTokens: Int
    public var claudeSourcePresent: Bool
    /// Dollars from the injected price callback. The default callback returns zeros.
    public var monthUSD: Double
    public var pricedTokens: Int
    public var unpricedTokens: Int

    public init(dayTokens: Int = 0, dayTokensPerHour: Int = 0, daySessions: Int = 0, monthTokens: Int = 0, claudeSourcePresent: Bool = false, monthUSD: Double = 0, pricedTokens: Int = 0, unpricedTokens: Int = 0) {
        self.dayTokens = dayTokens
        self.dayTokensPerHour = dayTokensPerHour
        self.daySessions = daySessions
        self.monthTokens = monthTokens
        self.claudeSourcePresent = claudeSourcePresent
        self.monthUSD = monthUSD
        self.pricedTokens = pricedTokens
        self.unpricedTokens = unpricedTokens
    }

    public var dictionary: [String: TranscriptField] {
        [
            "dayTokens": .int(dayTokens),
            "dayTokensPerHour": .int(dayTokensPerHour),
            "daySessions": .int(daySessions),
            "monthTokens": .int(monthTokens),
            "claudeSourcePresent": .bool(claudeSourcePresent),
        ]
    }
}

/// Walks `**/*.jsonl` the way tokenserver `_parse_file` / `_compute` does.
public final class TranscriptScanner {
    public static func zeroPrice(_ model: String?, _ usage: ClaudeUsage) -> (usd: Double, unpricedTokens: Int) {
        (0, 0)
    }

    private struct Row {
        var day: String
        var timestamp: TimeInterval
        var tokens: Int
        var session: String
        var dedupKey: String?
        var usd: Double
        var unpriced: Int
    }

    private struct CachedFile {
        var mtimeSec: Int64
        var mtimeNsec: Int64
        var size: Int64
        var dev: UInt64
        var ino: UInt64
        var offset: Int
        var month: String
        var records: [Row]
    }

    private var cache: [String: CachedFile] = [:]

    public init() {}

    public func compute(projectsDirectory: URL, now: Date = Date(), price: @escaping ClaudePrice = TranscriptScanner.zeroPrice) -> TranscriptScan {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.year, .month], from: now)
        var startParts = DateComponents()
        startParts.year = parts.year
        startParts.month = parts.month
        startParts.day = 1
        startParts.hour = 0
        startParts.minute = 0
        startParts.second = 0
        let monthStart = calendar.date(from: startParts) ?? now
        let monthKey = String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
        let today = Self.dayString(now)
        let hourAgo = now.timeIntervalSince1970 - 3600
        var isDirectory: ObjCBool = false
        let present = FileManager.default.fileExists(atPath: projectsDirectory.path, isDirectory: &isDirectory) && isDirectory.boolValue
        var live = Set<String>()
        if present {
            for url in Self.jsonlFiles(under: projectsDirectory) {
                guard let stamp = Self.stamp(url) else { continue }
                let mtime = Date(timeIntervalSince1970: TimeInterval(stamp.mtimeSec) + TimeInterval(stamp.mtimeNsec) / 1e9)
                if mtime < monthStart { continue }
                let key = url.path
                live.insert(key)
                if let cached = cache[key], cached.mtimeSec == stamp.mtimeSec, cached.mtimeNsec == stamp.mtimeNsec,
                   cached.size == stamp.size, cached.dev == stamp.dev, cached.ino == stamp.ino {
                    continue
                }
                let cached = cache[key]
                let canAppend = cached != nil && cached?.month == monthKey && cached?.dev == stamp.dev && cached?.ino == stamp.ino && stamp.size > (cached?.size ?? 0)
                if canAppend, var cached {
                    let parsed = Self.parseFile(url, monthStart: monthStart, offset: cached.offset, price: price)
                    cached.records.append(contentsOf: parsed.rows)
                    cached.mtimeSec = stamp.mtimeSec
                    cached.mtimeNsec = stamp.mtimeNsec
                    cached.size = stamp.size
                    cached.offset = parsed.offset
                    cache[key] = cached
                } else {
                    let parsed = Self.parseFile(url, monthStart: monthStart, offset: 0, price: price)
                    cache[key] = CachedFile(
                        mtimeSec: stamp.mtimeSec, mtimeNsec: stamp.mtimeNsec, size: stamp.size,
                        dev: stamp.dev, ino: stamp.ino, offset: parsed.offset, month: monthKey, records: parsed.rows
                    )
                }
            }
        }
        for stale in Set(cache.keys).subtracting(live) { cache.removeValue(forKey: stale) }
        var dayTokens = 0
        var monthTokens = 0
        var hourTokens = 0
        var monthUSD = 0.0
        var pricedTokens = 0
        var unpricedTokens = 0
        var sessions = Set<String>()
        var seen = Set<String>()
        for entry in cache.values {
            for row in entry.records {
                if let key = row.dedupKey {
                    if seen.contains(key) { continue }
                    seen.insert(key)
                }
                monthTokens += row.tokens
                monthUSD += row.usd
                if row.unpriced != 0 {
                    unpricedTokens += row.unpriced
                } else {
                    pricedTokens += row.tokens
                }
                if row.day == today {
                    dayTokens += row.tokens
                    sessions.insert(row.session)
                }
                if row.timestamp >= hourAgo { hourTokens += row.tokens }
            }
        }
        return TranscriptScan(
            dayTokens: dayTokens,
            dayTokensPerHour: hourTokens,
            daySessions: sessions.count,
            monthTokens: monthTokens,
            claudeSourcePresent: present,
            monthUSD: monthUSD,
            pricedTokens: pricedTokens,
            unpricedTokens: unpricedTokens
        )
    }

    private struct Stamp {
        var mtimeSec: Int64
        var mtimeNsec: Int64
        var size: Int64
        var dev: UInt64
        var ino: UInt64
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

    private static func jsonlFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in true }) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            files.append(url)
        }
        return files
    }

    private static func parseFile(_ url: URL, monthStart: Date, offset: Int, price: ClaudePrice) -> (rows: [Row], offset: Int) {
        guard let data = try? Data(contentsOf: url) else { return ([], offset) }
        let bytes = [UInt8](data)
        guard offset >= 0, offset <= bytes.count else { return ([], offset) }
        var rows: [Row] = []
        var index = offset
        var lineStart = offset
        var parsedUntil = offset
        while index < bytes.count {
            if bytes[index] == 0x0A {
                parseLine(Data(bytes[lineStart..<index]), path: url.path, monthStart: monthStart, price: price, into: &rows)
                index += 1
                lineStart = index
                parsedUntil = lineStart
                continue
            }
            index += 1
        }
        if lineStart < bytes.count { parsedUntil = lineStart }
        return (rows, parsedUntil)
    }

    private static func parseLine(_ line: Data, path: String, monthStart: Date, price: ClaudePrice, into rows: inout [Row]) {
        guard let entry = JSON.object(from: line), let message = JSON.dictionary(entry["message"]),
              let usage = JSON.dictionary(message["usage"]), !usage.isEmpty,
              let rawTimestamp = JSON.string(entry["timestamp"]),
              let instant = Instants.parse(rawTimestamp, naiveZone: .current) else { return }
        let stamp = Date(timeIntervalSince1970: instant)
        guard stamp >= monthStart else { return }
        let tokens = token(usage, "input_tokens") + token(usage, "output_tokens")
            + token(usage, "cache_creation_input_tokens") + token(usage, "cache_read_input_tokens")
        guard tokens > 0 else { return }
        let model = JSON.string(message["model"])
        let counted = ClaudeUsage(
            inputTokens: token(usage, "input_tokens"),
            outputTokens: token(usage, "output_tokens"),
            cacheCreationInputTokens: token(usage, "cache_creation_input_tokens"),
            cacheReadInputTokens: token(usage, "cache_read_input_tokens")
        )
        let priced = price(model, counted)
        let messageID = JSON.string(message["id"])
        let requestID = JSON.string(entry["requestId"])
        let key: String?
        if let messageID, let requestID, !messageID.isEmpty, !requestID.isEmpty {
            key = "\(messageID):\(requestID)"
        } else {
            key = nil
        }
        let session = JSON.string(entry["sessionId"]).flatMap { $0.isEmpty ? nil : $0 } ?? path
        rows.append(Row(day: dayString(stamp), timestamp: instant, tokens: tokens, session: session, dedupKey: key, usd: priced.usd, unpriced: priced.unpricedTokens))
    }

    private static func token(_ usage: [String: Any], _ key: String) -> Int {
        guard let number = JSON.finite(usage[key]), let int = Int(exactly: number.rounded(.towardZero)) else { return 0 }
        return int
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
