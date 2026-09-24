import Foundation

/// Read-only view of `claude-statusline-quota.json`. This does not write the
/// sample, take the lock, or run the statusLine hook.
public enum StatuslineSample {
    public static let sampleName = "claude-statusline-quota.json"
    public static let configName = "claude-statusline-bridge.json"
    public static let freshSeconds = 900
    public static let accountKey = "single"
    public static let sampleMaxBytes = 65_536

    public struct Peek: Sendable, Equatable {
        public var status: String
        public var document: Document?

        public init(status: String, document: Document?) {
            self.status = status
            self.document = document
        }
    }

    /// The `single` account from a sample. Other accounts are shape-checked by
    /// `peek` and not returned.
    public struct Document: Sendable, Equatable {
        public var fiveHour: StoredWindow?
        public var sevenDay: StoredWindow?
        public var claudeCodeVersion: String?

        public init(fiveHour: StoredWindow? = nil, sevenDay: StoredWindow? = nil,
                    claudeCodeVersion: String? = nil) {
            self.fiveHour = fiveHour
            self.sevenDay = sevenDay
            self.claudeCodeVersion = claudeCodeVersion
        }
    }

    public struct StoredWindow: Sendable, Equatable {
        public var pct: Double
        public var resetsAt: Double
        public var at: Double
        public var seen: Double

        public init(pct: Double, resetsAt: Double, at: Double, seen: Double) {
            self.pct = pct
            self.resetsAt = resetsAt
            self.at = at
            self.seen = seen
        }
    }

    public struct Window: Sendable, Equatable {
        public var pct: Double
        public var resetsAt: Double
        public var at: Double
        public var seen: Double
        public var ageS: Int
        public var fresh: Bool

        public init(pct: Double, resetsAt: Double, at: Double, seen: Double, ageS: Int, fresh: Bool) {
            self.pct = pct
            self.resetsAt = resetsAt
            self.at = at
            self.seen = seen
            self.ageS = ageS
            self.fresh = fresh
        }
    }

    public struct Summary: Sendable, Equatable {
        public var status: String
        public var ageS: Int?
        public var claudeCodeVersion: String?
        public var windows: [String: Window]

        public init(status: String, ageS: Int?, claudeCodeVersion: String?, windows: [String: Window]) {
            self.status = status
            self.ageS = ageS
            self.claudeCodeVersion = claudeCodeVersion
            self.windows = windows
        }
    }

    public static func sampleURL(in directory: URL) -> URL {
        directory.appendingPathComponent(sampleName)
    }

    public static func configURL(in directory: URL) -> URL {
        directory.appendingPathComponent(configName)
    }

    /// `missing`, `unreadable`, `invalid`, or `ok`. Never renames or rewrites the file.
    public static func peek(_ url: URL) -> Peek {
        let size: Int64
        do {
            size = try byteSize(url)
        } catch {
            return Peek(status: isMissing(error) ? "missing" : "unreadable", document: nil)
        }
        if size > Int64(sampleMaxBytes) {
            return Peek(status: "invalid", document: nil)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return Peek(status: isMissing(error) ? "missing" : "unreadable", document: nil)
        }
        if data.count > sampleMaxBytes || data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return Peek(status: "invalid", document: nil)
        }
        guard let object = jsonObject(data), wellFormed(object) else {
            return Peek(status: "invalid", document: nil)
        }
        return Peek(status: "ok", document: singleAccount(object))
    }

    public static func summarize(_ document: Document?, now: Int) -> Summary {
        guard let document else { return emptySummary(version: nil) }
        var windows: [String: Window] = [:]
        if let stored = document.fiveHour, running(stored, now: now, horizon: fiveHourHorizon) {
            windows["five_hour"] = window(stored, now: now)
        }
        if let stored = document.sevenDay, running(stored, now: now, horizon: sevenDayHorizon) {
            windows["seven_day"] = window(stored, now: now)
        }
        let version = printableVersion(document.claudeCodeVersion)
        guard !windows.isEmpty else { return emptySummary(version: version) }
        let age = windows.values.map(\.ageS).min() ?? 0
        return Summary(status: age <= freshSeconds ? "fresh" : "stale", ageS: age,
                       claudeCodeVersion: version, windows: windows)
    }

    /// Loose summarize of a JSON object. A nil or non-object payload is empty.
    /// This does not require `v == 1`; `peek` is what rejects a bad file.
    public static func summarize(json data: Data?, now: Int) -> Summary {
        guard let data, let object = jsonObject(data) else {
            return summarize(nil as Document?, now: now)
        }
        return summarize(singleAccount(object), now: now)
    }
}

private let fiveHourHorizon = 18_900
private let sevenDayHorizon = 691_200
private let versionMaxScalars = 64

private func emptySummary(version: String?) -> StatuslineSample.Summary {
    StatuslineSample.Summary(status: "empty", ageS: nil, claudeCodeVersion: version, windows: [:])
}

private func byteSize(_ url: URL) throws -> Int64 {
    let values = try url.resourceValues(forKeys: [.fileSizeKey])
    guard let size = values.fileSize else { throw CocoaError(.fileReadUnknown) }
    return Int64(size)
}

private func isMissing(_ error: Error) -> Bool {
    let ns = error as NSError
    if ns.domain == NSCocoaErrorDomain {
        return ns.code == CocoaError.fileReadNoSuchFile.rawValue
            || ns.code == CocoaError.fileNoSuchFile.rawValue
    }
    if ns.domain == NSPOSIXErrorDomain && ns.code == Int(POSIXError.ENOENT.rawValue) { return true }
    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
        return isMissing(underlying)
    }
    return false
}

private func jsonObject(_ data: Data) -> [String: Any]? {
    guard let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
    return value as? [String: Any]
}

private func finiteNumber(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber else { return nil }
    if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
    let double = number.doubleValue
    return double.isFinite ? double : nil
}

private func isIntegral(_ value: Any?) -> Bool {
    guard let double = finiteNumber(value) else { return false }
    return double == double.rounded(.towardZero)
}

private func storedWindow(_ value: Any?) -> StatuslineSample.StoredWindow? {
    guard let fields = value as? [String: Any],
          let pct = finiteNumber(fields["pct"]), (0...100).contains(pct),
          let resetsAt = finiteNumber(fields["resets_at"]), isIntegral(fields["resets_at"]),
          let at = finiteNumber(fields["at"]),
          let seen = finiteNumber(fields["seen"]) else { return nil }
    return StatuslineSample.StoredWindow(pct: pct, resetsAt: resetsAt, at: at, seen: seen)
}

private func wellFormed(_ object: [String: Any]) -> Bool {
    guard let version = finiteNumber(object["v"]), version == 1, isIntegral(object["v"]),
          let accounts = object["accounts"] as? [String: Any] else { return false }
    for entry in accounts.values {
        guard let entry = entry as? [String: Any] else { return false }
        for name in ["five_hour", "seven_day"] where entry[name] != nil {
            if storedWindow(entry[name]) == nil { return false }
        }
        if let version = entry["claude_code_version"], !(version is String) { return false }
    }
    return true
}

private func singleAccount(_ object: [String: Any]) -> StatuslineSample.Document {
    guard let accounts = object["accounts"] as? [String: Any],
          let entry = accounts[StatuslineSample.accountKey] as? [String: Any] else {
        return StatuslineSample.Document()
    }
    return StatuslineSample.Document(
        fiveHour: storedWindow(entry["five_hour"]),
        sevenDay: storedWindow(entry["seven_day"]),
        claudeCodeVersion: entry["claude_code_version"] as? String)
}

private func running(_ window: StatuslineSample.StoredWindow, now: Int, horizon: Int) -> Bool {
    let moment = Double(now)
    return window.resetsAt > moment && window.resetsAt <= moment + Double(horizon)
}

private func window(_ stored: StatuslineSample.StoredWindow, now: Int) -> StatuslineSample.Window {
    let age = max(0, now - pythonInt(stored.seen))
    return StatuslineSample.Window(
        pct: stored.pct, resetsAt: stored.resetsAt, at: stored.at, seen: stored.seen,
        ageS: age, fresh: age <= StatuslineSample.freshSeconds)
}

private func pythonInt(_ value: Double) -> Int {
    guard value.isFinite else { return 0 }
    if value >= Double(Int.max) { return Int.max }
    if value <= Double(Int.min) { return Int.min }
    return Int(value.rounded(.towardZero))
}

private func printableVersion(_ value: String?) -> String? {
    guard let value, !value.isEmpty, value.unicodeScalars.allSatisfy(isPythonPrintable) else { return nil }
    let scalars = value.unicodeScalars
    guard scalars.count > versionMaxScalars else { return value }
    return String(String.UnicodeScalarView(scalars.prefix(versionMaxScalars)))
}

private func isPythonPrintable(_ scalar: Unicode.Scalar) -> Bool {
    if scalar == " " { return true }
    switch scalar.properties.generalCategory {
    case .control, .format, .surrogate, .privateUse, .unassigned,
         .spaceSeparator, .lineSeparator, .paragraphSeparator:
        return false
    default:
        return true
    }
}
