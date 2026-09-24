import Darwin
import Foundation

// Claude Code spawns this process on each status line. It validates stdin,
// merges the two rate-limit windows into the sample file, and exits 0.
// VibePulseState has no sample writer; the bytes match statusline_bridge.py
// (compact, sorted, ASCII JSON, mode 0600).

private let sampleName = "claude-statusline-quota.json"
private let lockName = "claude-statusline-quota.lock"
private let windowNames = ["five_hour", "seven_day"]
private let stdinMaxBytes = 256 * 1024
private let sampleMaxBytes = 64 * 1024
private let versionMaxScalars = 64
private let lockWait = Duration.milliseconds(500)
private let lockRetry: TimeInterval = 0.05

@main
enum StatuslineMain {
    static func main() {
        recordSample(
            readStdin(),
            directory: stateDirectory(CommandLine.arguments),
            now: Int(Date().timeIntervalSince1970))
        exit(0)
    }
}

// MARK: - Paths and stdin

private func defaultStateDirectory() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Application Support", isDirectory: true)
        .appendingPathComponent("VibePulse", isDirectory: true)
}

/// `--state-dir PATH` in pairs, the same walk as `parse_argv`. Anything else is ignored.
private func stateDirectory(_ arguments: [String]) -> URL {
    var index = 1
    var chosen: URL?
    while index + 1 < arguments.count {
        let flag = arguments[index]
        let value = arguments[index + 1]
        if flag == "--state-dir", !value.isEmpty {
            chosen = URL(fileURLWithPath: value, isDirectory: true)
        }
        index += 2
    }
    return chosen ?? defaultStateDirectory()
}

private func readStdin() -> Data {
    let handle = FileHandle.standardInput
    var data = Data()
    do {
        while data.count <= stdinMaxBytes {
            guard let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
            data.append(chunk)
        }
    } catch {
        return Data()
    }
    return data
}

// MARK: - JSON

private enum J: Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([J])
    case object([String: J])
}

private struct Rejected: Error {}
private struct IOFailure: Error {}

private func box(_ any: Any) -> J? {
    if any is NSNull { return .null }
    if let text = any as? String { return .string(text) }
    if let number = any as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
        let type = String(cString: number.objCType)
        if type == "d" || type == "f" { return .double(number.doubleValue) }
        return .int(Int(number.int64Value))
    }
    if let items = any as? [Any] {
        var boxed: [J] = []
        boxed.reserveCapacity(items.count)
        for item in items {
            guard let value = box(item) else { return nil }
            boxed.append(value)
        }
        return .array(boxed)
    }
    if let fields = any as? [String: Any] {
        var object: [String: J] = [:]
        for (key, value) in fields {
            guard let boxed = box(value) else { return nil }
            object[key] = boxed
        }
        return .object(object)
    }
    return nil
}

private func parseJSON(_ data: Data) -> J? {
    guard String(bytes: data, encoding: .utf8) != nil else { return nil }
    guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
        return nil
    }
    return box(any)
}

/// Compact, sorted, `ensure_ascii` JSON. `/` is left alone. No trailing newline.
private func encode(_ value: J) -> String {
    switch value {
    case .null:
        return "null"
    case let .bool(flag):
        return flag ? "true" : "false"
    case let .int(number):
        return String(number)
    case let .double(number):
        return encodeDouble(number)
    case let .string(text):
        return quote(text)
    case let .array(items):
        return "[" + items.map(encode).joined(separator: ",") + "]"
    case let .object(fields):
        let body = fields.keys.sorted().map { key in
            quote(key) + ":" + encode(fields[key] ?? .null)
        }.joined(separator: ",")
        return "{" + body + "}"
    }
}

private func encodeDouble(_ value: Double) -> String {
    if value.isNaN { return "NaN" }
    if value == .infinity { return "Infinity" }
    if value == -.infinity { return "-Infinity" }
    let literal = String(value)
    if !literal.contains("."), !literal.contains("e"), !literal.contains("E") {
        return literal + ".0"
    }
    return literal
}

private func quote(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
        switch scalar.value {
        case 0x22: out += "\\\""
        case 0x5C: out += "\\\\"
        case 0x08: out += "\\b"
        case 0x0C: out += "\\f"
        case 0x0A: out += "\\n"
        case 0x0D: out += "\\r"
        case 0x09: out += "\\t"
        case 0x00...0x1F:
            out += String(format: "\\u%04x", scalar.value)
        default:
            if scalar.value > 0xFFFF {
                let rest = scalar.value - 0x10000
                let high = 0xD800 + (rest >> 10)
                let low = 0xDC00 + (rest & 0x3FF)
                out += String(format: "\\u%04x\\u%04x", high, low)
            } else if scalar.value > 0x7E {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    out += "\""
    return out
}

/// Python `==` for the sample: `42 == 42.0` and `True == 1`.
private func pyEqual(_ lhs: J, _ rhs: J) -> Bool {
    if let left = pyNumber(lhs), let right = pyNumber(rhs) { return left == right }
    switch (lhs, rhs) {
    case (.null, .null):
        return true
    case let (.string(left), .string(right)):
        return left == right
    case let (.array(left), .array(right)):
        return left.count == right.count && zip(left, right).allSatisfy(pyEqual)
    case let (.object(left), .object(right)):
        guard left.count == right.count else { return false }
        for (key, value) in left {
            guard let other = right[key], pyEqual(value, other) else { return false }
        }
        return true
    default:
        return false
    }
}

private func pyNumber(_ value: J) -> Double? {
    switch value {
    case let .bool(flag): return flag ? 1 : 0
    case let .int(number): return Double(number)
    case let .double(number) where number.isFinite: return number
    default: return nil
    }
}

private func finite(_ value: J?) -> Double? {
    switch value {
    case let .int(number): return Double(number)
    case let .double(number) where number.isFinite: return number
    default: return nil
    }
}

private func isIntegral(_ value: J?) -> Bool {
    switch value {
    case .int:
        return true
    case let .double(number):
        return number.isFinite && number == number.rounded(.towardZero)
    default:
        return false
    }
}

// MARK: - Payload

private struct Window {
    var pct: Double
    var resetsAt: Int
}

private struct Observed {
    var windows: [String: Window]
    var version: String?
}

private func horizon(_ name: String) -> Int {
    switch name {
    case "five_hour": return 5 * 3600 + 15 * 60
    case "seven_day": return 8 * 24 * 3600
    default: return 0
    }
}

private func parsePayload(_ raw: Data, now: Int) throws -> Observed {
    if raw.count > stdinMaxBytes { throw Rejected() }
    guard let root = parseJSON(raw), case let .object(payload) = root else { throw Rejected() }
    var windows: [String: Window] = [:]
    if let limits = payload["rate_limits"], limits != .null {
        guard case let .object(fields) = limits else { throw Rejected() }
        for name in windowNames where fields[name] != nil {
            windows[name] = try validateWindow(name, fields[name], now: now)
        }
    }
    return Observed(windows: windows, version: versionString(payload["version"]))
}

private func validateWindow(_ name: String, _ value: J?, now: Int) throws -> Window {
    guard case let .object(fields) = value else { throw Rejected() }
    guard let pct = finite(fields["used_percentage"]), pct >= 0, pct <= 100 else { throw Rejected() }
    guard let resetsAt = epoch(fields["resets_at"]) else { throw Rejected() }
    let limit = now + horizon(name)
    if resetsAt <= now || resetsAt > limit { throw Rejected() }
    return Window(pct: roundTenths(pct), resetsAt: resetsAt)
}

private func epoch(_ value: J?) -> Int? {
    switch value {
    case let .int(number):
        return number
    case let .double(number) where number.isFinite && number == number.rounded(.towardZero):
        guard number >= Double(Int.min), number < Double(Int.max) else { return nil }
        return Int(number)
    default:
        return nil
    }
}

/// `str.isprintable` and 1...64 code points. Anything else is "no version", not a rejection.
private func versionString(_ value: J?) -> String? {
    guard case let .string(text) = value else { return nil }
    let scalars = text.unicodeScalars
    if scalars.isEmpty || scalars.count > versionMaxScalars { return nil }
    for scalar in scalars {
        if scalar.value == 0x20 { continue }
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned,
             .spaceSeparator, .lineSeparator, .paragraphSeparator:
            return nil
        default:
            break
        }
    }
    return text
}

private func prefixScalars(_ text: String, _ maxCount: Int) -> String {
    var view = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
        if view.count == maxCount { break }
        view.append(scalar)
    }
    return String(view)
}

// MARK: - Merge

private func mergeEntry(_ stored: J?, _ observed: Observed, now: Int) -> [String: J] {
    let storedFields: [String: J]
    if case let .object(fields) = stored { storedFields = fields } else { storedFields = [:] }
    var entry: [String: J] = [:]
    for name in windowNames {
        let old = validWindow(storedFields[name], now: now, name: name)
        guard let new = observed.windows[name] else {
            if let old { entry[name] = .object(old) }
            continue
        }
        guard let old else {
            entry[name] = fresh(new, now: now)
            continue
        }
        let order = compareReset(new.resetsAt, old["resets_at"])
        let oldPct = finite(old["pct"]) ?? -1
        if order > 0 || (order == 0 && new.pct > oldPct) {
            entry[name] = fresh(new, now: now)
        } else if order == 0 {
            var copy = old
            copy["seen"] = .int(now)
            entry[name] = .object(copy)
        } else {
            // A cached window from before the stored reset. It did not observe
            // the current window, so it must not move `seen`.
            entry[name] = .object(old)
        }
    }
    var version = observed.version
    if version == nil, case let .string(text) = storedFields["claude_code_version"] {
        version = text
    }
    if let version, !version.isEmpty {
        entry["claude_code_version"] = .string(prefixScalars(version, versionMaxScalars))
    }
    return entry
}

private func fresh(_ window: Window, now: Int) -> J {
    .object([
        "pct": .double(window.pct),
        "resets_at": .int(window.resetsAt),
        "at": .int(now),
        "seen": .int(now),
    ])
}

private func compareReset(_ new: Int, _ old: J?) -> Int {
    switch old {
    case let .int(number):
        if new < number { return -1 }
        if new > number { return 1 }
        return 0
    case let .double(number):
        let current = Double(new)
        if current < number { return -1 }
        if current > number { return 1 }
        return 0
    default:
        return 1
    }
}

private func validWindow(_ value: J?, now: Int, name: String) -> [String: J]? {
    guard let value, case let .object(fields) = value, wellFormedWindow(value) else { return nil }
    guard let resets = finite(fields["resets_at"]) else { return nil }
    let nowNumber = Double(now)
    let limit = nowNumber + Double(horizon(name))
    guard resets > nowNumber, resets <= limit else { return nil }
    return fields
}

private func wellFormedWindow(_ value: J) -> Bool {
    guard case let .object(fields) = value else { return false }
    guard let pct = finite(fields["pct"]), pct >= 0, pct <= 100 else { return false }
    guard isIntegral(fields["resets_at"]), finite(fields["resets_at"]) != nil else { return false }
    guard finite(fields["at"]) != nil, finite(fields["seen"]) != nil else { return false }
    return true
}

private func isSampleVersion(_ value: J?) -> Bool {
    switch value {
    case .int(1), .bool(true): return true
    case let .double(number): return number == 1
    default: return false
    }
}

private func wellFormedDocument(_ value: J) -> Bool {
    guard case let .object(document) = value, isSampleVersion(document["v"]) else { return false }
    guard case let .object(accounts) = document["accounts"] else { return false }
    for entry in accounts.values {
        guard case let .object(fields) = entry else { return false }
        for name in windowNames {
            if let window = fields[name], !wellFormedWindow(window) { return false }
        }
        if let version = fields["claude_code_version"] {
            switch version {
            case .null, .string: break
            default: return false
            }
        }
    }
    return true
}

// MARK: - Sample file

private enum Loaded {
    case document(J)
    case unreadable
}

private func recordSample(_ raw: Data, directory: URL, now: Int) {
    let observed: Observed
    do {
        observed = try parsePayload(raw, now: now)
    } catch {
        return
    }
    let sample = directory.appendingPathComponent(sampleName)
    let lockURL = directory.appendingPathComponent(lockName)
    guard let lock = HeldLock.acquire(lockURL, wait: lockWait) else { return }
    defer { lock.release() }
    guard case let .document(document) = loadSample(sample) else { return }
    let accounts = accountMap(document)
    let before = accounts["single"]
    let merged = mergeEntry(before, observed, now: now)
    let hasWindow = windowNames.contains { merged[$0] != nil }
    let after: J? = hasWindow ? .object(merged) : nil
    if sameEntry(before, after) { return }
    var updated = accounts
    if let after {
        updated["single"] = after
    } else {
        updated.removeValue(forKey: "single")
    }
    let payload = encode(.object([
        "v": .int(1),
        "accounts": .object(updated),
    ]))
    do {
        try atomicWrite(Data(payload.utf8), to: sample)
    } catch {
        return
    }
}

private func accountMap(_ document: J) -> [String: J] {
    guard case let .object(root) = document, case let .object(accounts) = root["accounts"] else {
        return [:]
    }
    return accounts
}

private func sameEntry(_ before: J?, _ after: J?) -> Bool {
    switch (before, after) {
    case (nil, nil): return true
    case let (left?, right?): return pyEqual(left, right)
    default: return false
    }
}

private enum ReadJSON {
    case missing
    case unreadable
    case corrupt(String)
    case value(J)
}

private func loadSample(_ url: URL) -> Loaded {
    switch readBounded(url, limit: sampleMaxBytes) {
    case .missing:
        return .document(.object([:]))
    case .unreadable:
        return .unreadable
    case let .corrupt(reason):
        quarantine(url, reason: reason)
        return .document(.object([:]))
    case let .value(document):
        if wellFormedDocument(document) { return .document(document) }
        quarantine(url, reason: "not the v1 sample shape")
        return .document(.object([:]))
    }
}

private func readBounded(_ url: URL, limit: Int) -> ReadJSON {
    let inspected: Inspect
    do {
        inspected = try inspect(url)
    } catch InspectError.missing {
        return .missing
    } catch {
        return .unreadable
    }
    switch inspected {
    case .directory:
        return .unreadable
    case let .file(size) where size > Int64(limit):
        return .corrupt("larger than the bound")
    case .file:
        break
    }
    let data: Data
    do {
        data = try Data(contentsOf: url)
    } catch let error as NSError {
        return isMissing(error) ? .missing : .unreadable
    }
    guard String(bytes: data, encoding: .utf8) != nil else { return .corrupt("UnicodeDecodeError") }
    do {
        let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let value = box(any) else { return .corrupt("JSONDecodeError") }
        return .value(value)
    } catch {
        return .corrupt("JSONDecodeError")
    }
}

private enum Inspect {
    case file(Int64)
    case directory
}

private enum InspectError: Error {
    case missing
    case unreadable
}

private func inspect(_ url: URL) throws -> Inspect {
    let attributes: [FileAttributeKey: Any]
    do {
        attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    } catch let error as NSError {
        throw isMissing(error) ? InspectError.missing : InspectError.unreadable
    }
    if attributes[.type] as? FileAttributeType == .typeDirectory { return .directory }
    let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    return .file(size)
}

private func isMissing(_ error: NSError) -> Bool {
    if error.domain == NSCocoaErrorDomain {
        return error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError
    }
    if error.domain == NSPOSIXErrorDomain {
        return error.code == Int(ENOENT)
    }
    return false
}

private func quarantine(_ url: URL, reason: String) {
    let stamp = utcStamp()
    let directory = url.deletingLastPathComponent()
    let base = url.lastPathComponent
    var target = directory.appendingPathComponent("\(base).corrupt-\(stamp)")
    var counter = 1
    while FileManager.default.fileExists(atPath: target.path) {
        counter += 1
        target = directory.appendingPathComponent("\(base).corrupt-\(stamp)-\(counter)")
    }
    do {
        try FileManager.default.moveItem(at: url, to: target)
    } catch {
        warn("\(base) is unreadable (\(reason)) and could not be quarantined")
        return
    }
    try? fsyncParent(target)
    warn("\(base) is unreadable (\(reason)): quarantined as \(target.lastPathComponent)")
}

private func utcStamp() -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
    let year = parts.year ?? 0
    let month = parts.month ?? 0
    let day = parts.day ?? 0
    let hour = parts.hour ?? 0
    let minute = parts.minute ?? 0
    let second = parts.second ?? 0
    return String(format: "%04d%02d%02dT%02d%02d%02dZ", year, month, day, hour, minute, second)
}

private func warn(_ message: String) {
    var line = message
    line.append("\n")
    try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
}

private func atomicWrite(_ data: Data, to url: URL) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let tempURL = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
    let tempPath = tempURL.path
    let fd = tempPath.withCString { Darwin.open($0, O_CREAT | O_EXCL | O_WRONLY, mode_t(0o600)) }
    if fd < 0 { throw IOFailure() }
    var openFD = true
    var stillTemp = true
    do {
        if fchmod(fd, mode_t(0o600)) != 0 { throw IOFailure() }
        try writeAll(fd, data)
        if !fsyncLoop(fd) { throw IOFailure() }
        if Darwin.close(fd) != 0 { throw IOFailure() }
        openFD = false
        let renamed = tempPath.withCString { temp in
            url.path.withCString { dest in Darwin.rename(temp, dest) }
        }
        if renamed != 0 { throw IOFailure() }
        stillTemp = false
        try fsyncParent(url)
    } catch {
        if openFD { _ = Darwin.close(fd) }
        if stillTemp { _ = tempPath.withCString { Darwin.unlink($0) } }
        throw error
    }
}

private func writeAll(_ fd: Int32, _ data: Data) throws {
    if data.isEmpty { return }
    try data.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else { throw IOFailure() }
        var offset = 0
        while offset < buffer.count {
            let wrote = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
            if wrote < 0 {
                if errno == EINTR { continue }
                throw IOFailure()
            }
            if wrote == 0 { throw IOFailure() }
            offset += wrote
        }
    }
}

private func fsyncLoop(_ fd: Int32) -> Bool {
    while true {
        if fsync(fd) == 0 { return true }
        if errno != EINTR { return false }
    }
}

private func fsyncParent(_ url: URL) throws {
    let directory = url.deletingLastPathComponent().path
    let fd = directory.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY) }
    if fd < 0 { throw IOFailure() }
    defer { _ = Darwin.close(fd) }
    if !fsyncLoop(fd) { throw IOFailure() }
}

private final class HeldLock {
    private var fd: Int32

    private init(fd: Int32) { self.fd = fd }

    static func acquire(_ url: URL, wait: Duration) -> HeldLock? {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let fd = url.path.withCString { Darwin.open($0, O_RDWR | O_CREAT | O_APPEND, mode_t(0o644)) }
        if fd < 0 { return nil }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: wait)
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return HeldLock(fd: fd) }
            if errno == EINTR, clock.now < deadline { continue }
            if clock.now >= deadline {
                _ = Darwin.close(fd)
                return nil
            }
            Thread.sleep(forTimeInterval: lockRetry)
        }
    }

    func release() {
        guard fd >= 0 else { return }
        _ = flock(fd, LOCK_UN)
        _ = Darwin.close(fd)
        fd = -1
    }

    deinit { release() }
}

/// `round(x, 1)` on the exact binary value, ties toward the even tenth.
private func roundTenths(_ value: Double) -> Double {
    if value == 0 { return 0 }
    let bits = value.bitPattern
    let negative = bits >> 63 == 1
    let rawExponent = Int((bits >> 52) & 0x7FF)
    let fraction = bits & ((UInt64(1) << 52) - 1)
    let significand: UInt64
    let power: Int
    if rawExponent == 0 {
        significand = fraction
        power = -1074
    } else {
        significand = fraction | (UInt64(1) << 52)
        power = rawExponent - 1023 - 52
    }
    // value * 10 = significand * 5 * 2^(power + 1)
    let shiftPower = power + 1
    let magnitude = significand * 5
    var tenths: UInt64 = 0
    if shiftPower >= 0 {
        if shiftPower < 64 { tenths = magnitude << UInt64(shiftPower) }
    } else {
        let shift = -shiftPower
        if shift > 0, shift < 64 {
            let half = UInt64(1) << UInt64(shift - 1)
            let remainder = magnitude & ((UInt64(1) << UInt64(shift)) - 1)
            tenths = magnitude >> UInt64(shift)
            if remainder > half || (remainder == half && tenths & 1 == 1) {
                tenths += 1
            }
        }
    }
    let rounded = Double(tenths) / 10
    return negative ? -rounded : rounded
}
