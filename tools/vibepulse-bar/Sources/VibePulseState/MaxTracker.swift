import Darwin
import Foundation
import VibePulseSupport

public struct MaxTrackerProviderSnapshot: Equatable, Sendable {
    public var planLabel: String?
    public var avgPeakPct: Double?
    public var maxWeeksStreak: Int
    public var maxWeeks: Int
    public var maxDays: Int
    public var weekMaxed: [Int]
    public var days: [[Int]]
}

public struct MaxTrackerSnapshot: Equatable, Sendable {
    public var v: Int
    public var weeks: Int
    public var stale: Bool
    public var codingStreakDays: Int?
    public var claude: MaxTrackerProviderSnapshot
    public var codex: MaxTrackerProviderSnapshot
}

public final class MaxTrackerStore: @unchecked Sendable {
    public static let providers = ["claude", "codex"]
    public static let windowWeeks = 20
    public static let aggregateMax = 999
    public static let retentionDays = 400
    public static let planLabels = ["pro": "PRO", "max5x": "MAX 5X", "max20x": "MAX 20X", "plus": "PLUS"]

    public let path: URL
    private let codexRoot: URL?
    private let claudeRoot: URL?
    private let lock = NSRecursiveLock()
    private var loadError: String?
    private var days: [String: [String: Day]] = ["claude": [:], "codex": [:]]
    private var weeks: [String: [String: Bool]] = ["claude": [:], "codex": [:]]
    private var backfill: [String: [Int: Backfill]] = ["claude": [:], "codex": [:]]
    /// Bytes of an unfinished line. Memory only; the persisted offset stays behind them.
    private var pending: [String: [Int: Data]] = ["claude": [:], "codex": [:]]

    private struct Day {
        var pct: Int?
        var act: Bool
        var vol: Int?
        var lvl: Int?
        var hasLvl: Bool
    }

    private struct Backfill {
        var offset: Int
        var size: Int
        var done: Bool
        var discarding: Bool
    }

    public init(path: URL, codexRoot: URL? = nil, claudeRoot: URL? = nil) {
        self.path = path
        self.codexRoot = codexRoot
        self.claudeRoot = claudeRoot
        load()
    }

    public func observeQuota(provider: String, windowMinutes: Double?, pct: Double, timestamp: Double) {
        guard days[provider] != nil, pct.isFinite, (0...100).contains(pct), timestamp.isFinite else { return }
        let date = CivilDate.local(epoch: timestamp).isoString
        lock.lock()
        defer { lock.unlock() }
        if windowMinutes == nil {
            bump(provider, date, pct)
        } else if let windowMinutes, windowMinutes.isFinite, windowMinutes > 0 {
            if windowMinutes <= 600 {
                bump(provider, date, pct)
            } else if pct >= 100 {
                weeks[provider, default: [:]][dateWeek(date)] = true
            }
        }
    }

    public func observeVolume(provider: String, date: String, tokens: Double) {
        guard days[provider] != nil, tokens.isFinite, tokens > 0, CivilDate.parse(date) != nil else { return }
        lock.lock()
        defer { lock.unlock() }
        var day = days[provider, default: [:]][date] ?? Day(pct: nil, act: false, vol: nil, lvl: nil, hasLvl: false)
        day.act = true
        day.vol = (day.vol ?? 0) + Int(tokens)
        day.lvl = nil
        day.hasLvl = false
        days[provider, default: [:]][date] = day
    }

    public func snapshot(today: String, plans: [String: String] = [:]) -> MaxTrackerSnapshot {
        lock.lock()
        let state = copyState()
        lock.unlock()
        return buildPayload(state: state, today: today, plans: plans, stale: false)
    }

    public func save(today: String? = nil) throws {
        if let loadError {
            throw StatePersistenceError("\(path.lastPathComponent) was unreadable at startup (\(loadError)); refusing to overwrite it")
        }
        lock.lock()
        prune(today: today)
        let payload = persistedObject()
        lock.unlock()
        try StateFiles.atomicWrite(JSONWire.encode(payload), to: path)
        chmod(path.path, 0o600)
    }

    static func roundDayPct(_ pct: Double) -> Int {
        if pct >= 100 { return 100 }
        return min(Int(floor(pct + 0.5)), 99)
    }

    static func volumeLevels(_ volumes: [String: Int]) -> [String: Int] {
        let distinct = Array(Set(volumes.values.filter { $0 > 0 })).sorted()
        let count = distinct.count
        var rank: [Int: Int] = [:]
        for (index, volume) in distinct.enumerated() where count > 0 {
            rank[volume] = index * 3 / count
        }
        var out: [String: Int] = [:]
        for (day, volume) in volumes {
            out[day] = volume > 0 ? (rank[volume] ?? 0) : 0
        }
        return out
    }

    private func bump(_ provider: String, _ date: String, _ pct: Double) {
        var day = days[provider, default: [:]][date] ?? Day(pct: nil, act: false, vol: nil, lvl: nil, hasLvl: false)
        let rounded = Self.roundDayPct(pct)
        if day.pct == nil || rounded > day.pct! { day.pct = rounded }
        days[provider, default: [:]][date] = day
    }

    private func dateWeek(_ date: String) -> String {
        CivilDate.parse(date)?.weekKey ?? date
    }

    private func load() {
        switch StateIO.read(path) {
        case .missing:
            return
        case .notUTF8:
            StateFiles.quarantine(path, reason: "not UTF-8")
        case let .unreadable(name):
            loadError = name
        case let .data(data):
            guard let value = StateIO.parseObject(data) else {
                StateFiles.quarantine(path, reason: "invalid JSON at byte 0")
                return
            }
            guard let object = value.object else {
                StateFiles.quarantine(path, reason: "top level is not an object")
                return
            }
            guard Self.providers.allSatisfy({ validSection(object[$0]) }) else {
                StateFiles.quarantine(path, reason: "a provider section (claude/codex) is missing or not the {v, days, weeks, backfill} shape save() writes")
                return
            }
            for provider in Self.providers {
                loadProvider(provider, object[provider]!.object!)
            }
        }
    }

    private func validSection(_ value: StrictJSON.Value?) -> Bool {
        guard let object = value?.object, object["v"]?.int == 1,
              object["days"]?.object != nil, object["weeks"]?.object != nil,
              object["backfill"]?.object != nil else { return false }
        return true
    }

    private func loadProvider(_ provider: String, _ section: [String: StrictJSON.Value]) {
        for (day, value) in section["days"]?.object ?? [:] {
            guard CivilDate.parse(day) != nil, let record = value.object else { continue }
            let act = truthy(record["act"])
            var stored = Day(pct: nil, act: act, vol: nil, lvl: nil, hasLvl: false)
            if let pct = record["pct"]?.number, pct.isFinite, (0...100).contains(pct) {
                stored.pct = Self.roundDayPct(pct)
            }
            if act, let lvl = record["lvl"]?.int {
                stored.lvl = min(2, max(0, lvl))
                stored.hasLvl = true
            }
            days[provider, default: [:]][day] = stored
        }
        for (week, value) in section["weeks"]?.object ?? [:] where truthy(value) {
            weeks[provider, default: [:]][week] = true
        }
        for (key, value) in section["backfill"]?.object ?? [:] {
            guard key.unicodeScalars.allSatisfy({ ("0"..."9").contains(Character($0)) }),
                  let inode = Int(key), let entry = value.object,
                  let offset = entry["offset"]?.int, offset >= 0,
                  let size = entry["size"]?.int, size >= 0,
                  let done = entry["done"]?.bool else { continue }
            let discarding: Bool
            if entry["discarding"] == nil { discarding = false }
            else if let flag = entry["discarding"]?.bool { discarding = flag }
            else { continue }
            backfill[provider, default: [:]][inode] = Backfill(offset: offset, size: size, done: done, discarding: discarding)
        }
    }

    private func truthy(_ value: StrictJSON.Value?) -> Bool {
        switch value {
        case let .bool(flag): return flag
        case let .int(number): return number != 0
        case let .double(number): return number != 0 && number.isFinite
        case let .string(text): return !text.isEmpty
        case let .array(items): return !items.isEmpty
        case let .object(object): return !object.isEmpty
        default: return false
        }
    }

    private func prune(today: String?) {
        let anchor = today.flatMap(CivilDate.parse) ?? CivilDate.today()
        let cutoff = anchor.adding(days: -Self.retentionDays)
        let weekCutoff = cutoff.adding(days: -7)
        for provider in Self.providers {
            days[provider] = days[provider, default: [:]].filter { key, _ in
                guard let date = CivilDate.parse(key) else { return false }
                return date >= cutoff
            }
            weeks[provider] = weeks[provider, default: [:]].filter { key, _ in
                guard let monday = CivilDate.monday(ofWeekKey: key) else { return false }
                return monday >= weekCutoff
            }
        }
    }

    private func persistedObject() -> JSONValue {
        .object(Self.providers.map { provider in
            (provider, providerPayload(provider))
        })
    }

    private func providerPayload(_ provider: String) -> JSONValue {
        let bucket = days[provider, default: [:]]
        var rankable: [String: Int] = [:]
        for (day, record) in bucket where record.act && !record.hasLvl {
            rankable[day] = record.vol ?? 0
        }
        let levels = Self.volumeLevels(rankable)
        let dayPairs = bucket.keys.sorted().map { day -> (String, JSONValue) in
            let record = bucket[day]!
            let lvl: JSONValue
            if !record.act { lvl = .null }
            else if record.hasLvl { lvl = .int(record.lvl ?? 0) }
            else { lvl = .int(levels[day] ?? 0) }
            let pct: JSONValue = record.pct.map { .int(Self.roundDayPct(Double($0))) } ?? .null
            return (day, .object([("pct", pct), ("act", .bool(record.act)), ("lvl", lvl)]))
        }
        let weekPairs = bucketWeeks(provider).keys.sorted().map { ($0, JSONValue.bool(true)) }
        let fillPairs = backfill[provider, default: [:]].keys.sorted().map { inode -> (String, JSONValue) in
            let entry = backfill[provider]![inode]!
            return (String(inode), .object([
                ("offset", .int(entry.offset)), ("size", .int(entry.size)),
                ("done", .bool(entry.done)), ("discarding", .bool(entry.discarding)),
            ]))
        }
        return .object([
            ("v", .int(1)),
            ("days", .object(dayPairs)),
            ("weeks", .object(weekPairs)),
            ("backfill", .object(fillPairs)),
        ])
    }

    private func bucketWeeks(_ provider: String) -> [String: Bool] {
        weeks[provider, default: [:]].filter { $0.value }
    }

    private struct Memory {
        var days: [String: [String: Day]]
        var weeks: [String: [String: Bool]]
    }

    private func copyState() -> Memory {
        Memory(days: days, weeks: weeks)
    }

    private func buildPayload(state: Memory, today: String, plans: [String: String], stale: Bool) -> MaxTrackerSnapshot {
        var active = Set<String>()
        for provider in Self.providers {
            for (day, record) in state.days[provider, default: [:]] where record.act { active.insert(day) }
        }
        let streak: Int? = active.isEmpty ? nil : clamp(codingStreak(active, today))
        let windowKeys = windowWeekKeys(today)
        let thisWeek = CivilDate.parse(today)?.weekKey ?? today
        func providerSnapshot(_ provider: String) -> MaxTrackerProviderSnapshot {
            let merged = providerDays(state.days[provider, default: [:]])
            let grid = denseWindow(today: today, perDay: merged)
            let maxedWeeks = state.weeks[provider, default: [:]]
            let weekMaxed = windowKeys.map { maxedWeeks[$0] == true ? 1 : 0 }
            let real = grid.map(\.[0]).filter { $0 != -1 }
            let avg = real.isEmpty ? nil : PyRound.places(Double(real.reduce(0, +)) / Double(real.count), 1)
            let label = plans[provider].flatMap { Self.planLabels[$0] }
            let maxDays = merged.values.filter { $0.pct == 100 }.count
            return MaxTrackerProviderSnapshot(
                planLabel: label, avgPeakPct: avg,
                maxWeeksStreak: clamp(maxWeeksStreak(maxedWeeks, thisWeek)),
                maxWeeks: clamp(maxedWeeks.values.filter { $0 }.count),
                maxDays: clamp(maxDays), weekMaxed: weekMaxed, days: grid)
        }
        return MaxTrackerSnapshot(v: 1, weeks: Self.windowWeeks, stale: stale, codingStreakDays: streak,
                                 claude: providerSnapshot("claude"), codex: providerSnapshot("codex"))
    }

    private func providerDays(_ days: [String: Day]) -> [String: (pct: Int, lvl: Int)] {
        var rankable: [String: Int] = [:]
        for (day, record) in days where record.act && !record.hasLvl {
            rankable[day] = record.vol ?? 0
        }
        let levels = Self.volumeLevels(rankable)
        var merged: [String: (pct: Int, lvl: Int)] = [:]
        for (day, record) in days {
            let lvl: Int
            if !record.act { lvl = -1 }
            else if record.hasLvl { lvl = record.lvl ?? -1 }
            else { lvl = levels[day] ?? -1 }
            merged[day] = (record.pct ?? -1, lvl)
        }
        return merged
    }

    private func denseWindow(today: String, perDay: [String: (pct: Int, lvl: Int)]) -> [[Int]] {
        guard let todayDate = CivilDate.parse(today) else { return [] }
        let monday = todayDate.adding(days: 1 - todayDate.isoWeekday)
        let start = monday.adding(days: -7 * (Self.windowWeeks - 1))
        var out: [[Int]] = []
        for offset in 0..<(Self.windowWeeks * 7) {
            let day = start.adding(days: offset)
            if day > todayDate { out.append([-1, -1]); continue }
            guard let record = perDay[day.isoString] else { out.append([-1, -1]); continue }
            let pct = record.pct == -1 ? -1 : Self.roundDayPct(Double(record.pct))
            out.append([pct, record.lvl])
        }
        return out
    }

    private func windowWeekKeys(_ today: String) -> [String] {
        guard let todayDate = CivilDate.parse(today) else { return [] }
        let monday = todayDate.adding(days: 1 - todayDate.isoWeekday)
        let start = monday.adding(days: -7 * (Self.windowWeeks - 1))
        return (0..<Self.windowWeeks).map { start.adding(days: 7 * $0).weekKey }
    }

    private func codingStreak(_ active: Set<String>, _ today: String) -> Int {
        guard let todayDate = CivilDate.parse(today) else { return 0 }
        var cursor = active.contains(today) ? todayDate : todayDate.adding(days: -1)
        var streak = 0
        while active.contains(cursor.isoString) {
            streak += 1
            cursor = cursor.adding(days: -1)
        }
        return streak
    }

    private func maxWeeksStreak(_ maxed: [String: Bool], _ thisWeek: String) -> Int {
        guard var cursor = CivilDate.monday(ofWeekKey: thisWeek)?.adding(days: -7) else { return 0 }
        var streak = 0
        while maxed[cursor.weekKey] == true {
            streak += 1
            cursor = cursor.adding(days: -7)
        }
        return streak
    }

    private func clamp(_ value: Int) -> Int { min(Self.aggregateMax, max(0, value)) }

    // MARK: Backfill

    private static let backfillBlock = 64 * 1024
    private static let backfillRecords = 256
    private static let backfillLineCap = 8 * 1024 * 1024

    /// One bounded slice of Codex then Claude history. No background thread.
    /// Returns true while either root still has a file to drain.
    @discardableResult
    public func backfillStep(budgetBytes: Int = 1_048_576) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let codexMore = advanceOneFile(provider: "codex", root: codexRoot, kind: .rollout,
                                        budget: budgetBytes, cutoff: nil)
        let claudeMore = advanceOneFile(provider: "claude", root: claudeRoot, kind: .jsonl,
                                         budget: budgetBytes, cutoff: TrackerTime.monthStart())
        return codexMore || claudeMore
    }

    private enum ScanKind { case rollout, jsonl }

    private struct FileInfo {
        var inode: Int
        var size: Int
        var mtime: TimeInterval
    }

    private struct Drain {
        var offset: Int
        var pending: Data
        var discarding: Bool
        var danglingEOF: Bool
    }

    private func advanceOneFile(provider: String, root: URL?, kind: ScanKind, budget: Int,
                                cutoff: TimeInterval?) -> Bool {
        guard let root, isDirectory(root), let paths = matchingFiles(root, kind) else { return false }
        func deferred(_ info: FileInfo) -> Bool {
            guard let cutoff, info.mtime >= cutoff else { return false }
            // A started, unfinished file stays backfill-owned regardless of mtime.
            let entry = backfill[provider]?[info.inode]
            return entry == nil || entry?.done == true
        }
        var chosen: (URL, FileInfo, Backfill?)?
        for path in paths {
            guard let info = fileInfo(path) else { continue }
            if deferred(info) {
                advanceWatermark(provider, info)
                continue
            }
            if chosen != nil { continue }
            let entry = backfill[provider]?[info.inode]
            if isFullyDrained(entry, info) { continue }
            chosen = (path, info, entry)
        }
        guard let (path, info, entry) = chosen else { return false }
        let start: Int
        let discarding: Bool
        if entry == nil || (entry?.size ?? 0) > info.size {
            start = 0
            discarding = false
            setPending(provider, info.inode, nil)
        } else {
            start = entry?.offset ?? 0
            discarding = entry?.discarding ?? false
        }
        let buffered = discarding ? Data() : (pending[provider]?[info.inode] ?? Data())
        let drained = drainFile(path, start: start, budget: budget, pending: buffered, discarding: discarding) { event in
            if provider == "codex" { handleCodex(event) }
            else { handleClaude(event) }
        }
        let done = drained.danglingEOF || drained.offset >= info.size
        backfill[provider, default: [:]][info.inode] = Backfill(
            offset: drained.offset, size: info.size, done: done, discarding: drained.discarding)
        setPending(provider, info.inode, drained.pending.isEmpty ? nil : drained.pending)
        if !done { return true }
        setPending(provider, info.inode, nil)
        for other in paths where other.path != path.path {
            guard let otherInfo = fileInfo(other) else { continue }
            if deferred(otherInfo) { continue }
            if !isFullyDrained(backfill[provider]?[otherInfo.inode], otherInfo) { return true }
        }
        return false
    }

    private func isFullyDrained(_ entry: Backfill?, _ info: FileInfo) -> Bool {
        guard let entry else { return false }
        return entry.done && entry.size == info.size
    }

    private func advanceWatermark(_ provider: String, _ info: FileInfo) {
        if let existing = backfill[provider]?[info.inode], !existing.done { return }
        backfill[provider, default: [:]][info.inode] = Backfill(
            offset: info.size, size: info.size, done: true, discarding: false)
        setPending(provider, info.inode, nil)
    }

    private func setPending(_ provider: String, _ inode: Int, _ data: Data?) {
        var bucket = pending[provider] ?? [:]
        if let data, !data.isEmpty { bucket[inode] = data }
        else { bucket.removeValue(forKey: inode) }
        pending[provider] = bucket
    }

    private func drainFile(_ path: URL, start: Int, budget: Int, pending pendingBuf: Data, discarding discardingIn: Bool,
                           handler: (StrictJSON.Value) -> Void) -> Drain {
        var offset = start
        let seek = start + (discardingIn ? 0 : pendingBuf.count)
        var records = 0
        var bytesRead = 0
        var buf = discardingIn ? Data() : pendingBuf
        var discarding = discardingIn
        var hitEOF = false
        let fd = open(path.path, O_RDONLY)
        if fd < 0 { return Drain(offset: start, pending: pendingBuf, discarding: discardingIn, danglingEOF: false) }
        defer { close(fd) }
        if lseek(fd, off_t(seek), SEEK_SET) < 0 {
            return Drain(offset: start, pending: pendingBuf, discarding: discardingIn, danglingEOF: false)
        }
        var scratch = [UInt8](repeating: 0, count: Self.backfillBlock)
        while records < Self.backfillRecords {
            if discarding {
                if bytesRead >= budget { break }
                let want = min(Self.backfillBlock, budget - bytesRead)
                let count = readBytes(fd, &scratch, want)
                if count < 0 {
                    return Drain(offset: start, pending: pendingBuf, discarding: discardingIn, danglingEOF: false)
                }
                if count == 0 { hitEOF = true; break }
                bytesRead += count
                let chunk = Data(scratch.prefix(count))
                if let newline = chunk.firstIndex(of: 0x0A) {
                    let distance = chunk.distance(from: chunk.startIndex, to: newline)
                    discarding = false
                    records += 1
                    offset += distance + 1
                    let rest = chunk.index(after: newline)
                    buf = rest < chunk.endIndex ? chunk.subdata(in: rest..<chunk.endIndex) : Data()
                } else {
                    offset += count
                }
                continue
            }
            if let newline = buf.firstIndex(of: 0x0A) {
                let line = buf.subdata(in: buf.startIndex..<newline)
                let distance = buf.distance(from: buf.startIndex, to: newline)
                let rest = buf.index(after: newline)
                buf = rest < buf.endIndex ? buf.subdata(in: rest..<buf.endIndex) : Data()
                offset += distance + 1
                records += 1
                if !isBlankLine(line), let event = parseEvent(line) { handler(event) }
                continue
            }
            if buf.count > Self.backfillLineCap {
                discarding = true
                offset += buf.count
                buf.removeAll(keepingCapacity: false)
                continue
            }
            if bytesRead >= budget { break }
            let want = min(Self.backfillBlock, budget - bytesRead)
            let count = readBytes(fd, &scratch, want)
            if count < 0 {
                return Drain(offset: start, pending: pendingBuf, discarding: discardingIn, danglingEOF: false)
            }
            if count == 0 { hitEOF = true; break }
            bytesRead += count
            buf.append(contentsOf: scratch.prefix(count))
        }
        if hitEOF && !discarding && !buf.isEmpty {
            return Drain(offset: offset, pending: Data(), discarding: false, danglingEOF: true)
        }
        return Drain(offset: offset, pending: discarding ? Data() : buf, discarding: discarding, danglingEOF: false)
    }

    private func readBytes(_ fd: Int32, _ buffer: inout [UInt8], _ count: Int) -> Int {
        buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.read(fd, base, count)
        }
    }

    private func isBlankLine(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func parseEvent(_ data: Data) -> StrictJSON.Value? {
        guard case let .success(value) = StrictJSON.parse(data) else { return nil }
        return value
    }

    private func handleCodex(_ event: StrictJSON.Value) {
        guard let limits = codexRateLimits(event) else { return }
        if let name = limits["limit_name"], !isJSONNull(name) {
            if name.string == nil || name.string?.isEmpty == false { return }
        }
        guard let stamp = event.object?["timestamp"]?.string,
              let truncated = TrackerTime.truncatedEpoch(stamp) else { return }
        let date = CivilDate.local(epoch: TimeInterval(truncated)).isoString
        var found = false
        for key in ["primary", "secondary"] {
            guard let parsed = backfillWindow(limits[key]) else { continue }
            found = true
            if parsed.minutes <= 600 {
                bump("codex", date, Double(parsed.pct))
            } else if parsed.pct >= 100 {
                weeks["codex", default: [:]][dateWeek(date)] = true
            }
        }
        if found {
            var day = days["codex", default: [:]][date] ?? Day(pct: nil, act: false, vol: nil, lvl: nil, hasLvl: false)
            day.act = true
            days["codex", default: [:]][date] = day
        }
    }

    private func backfillWindow(_ value: StrictJSON.Value?) -> (pct: Int, minutes: Double)? {
        guard let window = value?.object,
              let pct = window["used_percent"]?.number, pct.isFinite, (0...100).contains(pct),
              let minutes = window["window_minutes"]?.number, minutes.isFinite, minutes > 0 else { return nil }
        return (Self.roundDayPct(pct), minutes)
    }

    private func codexRateLimits(_ event: StrictJSON.Value) -> [String: StrictJSON.Value]? {
        guard let object = event.object, object["type"]?.string == "event_msg",
              let payload = object["payload"]?.object, payload["type"]?.string == "token_count",
              let limits = payload["rate_limits"]?.object else { return nil }
        return limits
    }

    private func handleClaude(_ event: StrictJSON.Value) {
        guard let object = event.object else { return }
        guard let message = object["message"], !pythonFalsy(message), let messageObject = message.object else { return }
        guard let usageValue = messageObject["usage"], !pythonFalsy(usageValue),
              let usage = usageValue.object else { return }
        guard let stamp = object["timestamp"], !pythonFalsy(stamp), let text = stamp.string,
              let instant = TrackerTime.epoch(text), instant.isFinite else { return }
        if instant >= TrackerTime.monthStart() { return }
        guard let tokens = claudeTokens(usage), tokens.isFinite, tokens > 0 else { return }
        observeVolume(provider: "claude", date: CivilDate.local(epoch: instant).isoString, tokens: tokens)
    }

    private func claudeTokens(_ usage: [String: StrictJSON.Value]) -> Double? {
        var sum = 0.0
        for key in ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"] {
            guard let part = pythonOrZero(usage[key]) else { return nil }
            sum += part
        }
        return sum
    }

    private func pythonOrZero(_ value: StrictJSON.Value?) -> Double? {
        guard let value else { return 0 }
        if pythonFalsy(value) { return 0 }
        switch value {
        case let .bool(flag): return flag ? 1 : 0
        case let .int(number): return Double(number)
        case let .double(number): return number
        default: return nil
        }
    }

    private func pythonFalsy(_ value: StrictJSON.Value) -> Bool {
        switch value {
        case .null: return true
        case let .bool(flag): return !flag
        case let .int(number): return number == 0
        case let .double(number): return number == 0
        case let .string(text): return text.isEmpty
        case let .array(items): return items.isEmpty
        case let .object(object): return object.isEmpty
        }
    }

    private func isJSONNull(_ value: StrictJSON.Value) -> Bool {
        if case .null = value { return true }
        return false
    }

    private func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    private func fileInfo(_ url: URL) -> FileInfo? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        guard let inode = Int(exactly: info.st_ino), let size = Int(exactly: info.st_size), size >= 0 else { return nil }
        let mtime = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return FileInfo(inode: inode, size: size, mtime: mtime)
    }

    private func matchingFiles(_ root: URL, _ kind: ScanKind) -> [URL]? {
        var failed = false
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [],
            errorHandler: { _, _ in
                failed = true
                return false
            }
        ) else { return nil }
        var found: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            guard nameMatches(item.lastPathComponent, kind) else { continue }
            var info = stat()
            guard stat(item.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            found.append(item)
        }
        if failed { return nil }
        found.sort { pathLess(relativeParts($0, root), relativeParts($1, root)) }
        return found
    }

    private func nameMatches(_ name: String, _ kind: ScanKind) -> Bool {
        switch kind {
        case .rollout: return name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
        case .jsonl: return name.hasSuffix(".jsonl")
        }
    }

    private func relativeParts(_ url: URL, _ root: URL) -> [String] {
        func parts(_ path: String, _ rootPath: String) -> [String]? {
            if path == rootPath { return [] }
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            guard path.hasPrefix(prefix) else { return nil }
            return path.dropFirst(prefix.count).split(separator: "/").map(String.init)
        }
        if let direct = parts(url.path, root.path) { return direct }
        return parts(url.standardizedFileURL.path, root.standardizedFileURL.path) ?? [url.lastPathComponent]
    }

    private func pathLess(_ lhs: [String], _ rhs: [String]) -> Bool {
        let count = min(lhs.count, rhs.count)
        for index in 0..<count where lhs[index] != rhs[index] { return lhs[index] < rhs[index] }
        return lhs.count < rhs.count
    }
}

/// Local calendar instants. Month start keeps today's UTC offset, matching
/// `datetime.now().astimezone().replace(day=1, ...)`.
private enum TrackerTime {
    static func monthStart(_ now: Date = Date(), zone: TimeZone = .current) -> TimeInterval {
        let fixed = TimeZone(secondsFromGMT: zone.secondsFromGMT(for: now)) ?? zone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = fixed
        let parts = calendar.dateComponents([.year, .month], from: now)
        var start = DateComponents()
        start.calendar = calendar
        start.timeZone = fixed
        start.year = parts.year
        start.month = parts.month
        start.day = 1
        return calendar.date(from: start)?.timeIntervalSince1970 ?? now.timeIntervalSince1970
    }

    static func truncatedEpoch(_ text: String) -> Int? {
        guard let instant = epoch(text), instant.isFinite,
              instant < Double(Int.max), instant > Double(Int.min) else { return nil }
        return Int(instant)
    }

    static func epoch(_ raw: String, zone: TimeZone = .current) -> TimeInterval? {
        let bytes = Array(raw.replacingOccurrences(of: "Z", with: "+00:00").utf8)
        guard bytes.count >= 10, bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
              let year = digits(bytes, 0, 4), let month = digits(bytes, 5, 2),
              let day = digits(bytes, 8, 2) else { return nil }
        var index = 10
        var hour = 0
        var minute = 0
        var second = 0
        var nanosecond = 0
        if index < bytes.count {
            let separator = bytes[index]
            if separator == UInt8(ascii: "T") || separator == UInt8(ascii: "t") || separator == UInt8(ascii: " ") {
                index += 1
                guard let parsedHour = digits(bytes, index, 2),
                      index + 2 < bytes.count, bytes[index + 2] == UInt8(ascii: ":"),
                      let parsedMinute = digits(bytes, index + 3, 2) else { return nil }
                hour = parsedHour
                minute = parsedMinute
                index += 5
                if index < bytes.count, bytes[index] == UInt8(ascii: ":") {
                    guard let parsedSecond = digits(bytes, index + 1, 2) else { return nil }
                    second = parsedSecond
                    index += 3
                }
                if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                    index += 1
                    let start = index
                    while index < bytes.count, bytes[index] >= UInt8(ascii: "0"), bytes[index] <= UInt8(ascii: "9") {
                        index += 1
                    }
                    if start == index { return nil }
                    var fraction = 0
                    var scale = 100_000_000
                    for (offset, byte) in bytes[start..<index].enumerated() where offset < 9 {
                        fraction += Int(byte - UInt8(ascii: "0")) * scale
                        scale /= 10
                    }
                    nanosecond = fraction
                }
            }
        }
        var offset: Int?
        if index < bytes.count {
            let signByte = bytes[index]
            guard signByte == UInt8(ascii: "+") || signByte == UInt8(ascii: "-") else { return nil }
            let sign = signByte == UInt8(ascii: "-") ? -1 : 1
            index += 1
            guard let hours = digits(bytes, index, 2) else { return nil }
            index += 2
            var minutes = 0
            if index < bytes.count {
                if bytes[index] == UInt8(ascii: ":") { index += 1 }
                guard let parsed = digits(bytes, index, 2) else { return nil }
                minutes = parsed
                index += 2
            }
            guard (0...23).contains(hours), (0...59).contains(minutes) else { return nil }
            offset = sign * (hours * 3600 + minutes * 60)
        }
        guard index == bytes.count else { return nil }
        let timeZone = offset.flatMap { TimeZone(secondsFromGMT: $0) } ?? zone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var parts = DateComponents()
        parts.calendar = calendar
        parts.timeZone = timeZone
        parts.year = year
        parts.month = month
        parts.day = day
        parts.hour = hour
        parts.minute = minute
        parts.second = second
        parts.nanosecond = nanosecond
        return calendar.date(from: parts)?.timeIntervalSince1970
    }

    private static func digits(_ bytes: [UInt8], _ start: Int, _ count: Int) -> Int? {
        guard start >= 0, count > 0, start + count <= bytes.count else { return nil }
        var value = 0
        for offset in 0..<count {
            let byte = bytes[start + offset]
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
            value = value * 10 + Int(byte - UInt8(ascii: "0"))
        }
        return value
    }
}
