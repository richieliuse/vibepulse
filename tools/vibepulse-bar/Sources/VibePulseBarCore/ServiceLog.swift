import Darwin
import Foundation

/// The service log the child writes into, shared with the LaunchAgent path.
///
/// Opened `O_APPEND` exactly like launchd's `StandardErrorPath`: the server
/// rotates its own log by truncating the file in place, and only an
/// append-mode descriptor follows that truncation instead of writing past a
/// hole at the old offset.
public struct ServiceLog: Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    /// A fresh append-mode handle for a child's stdout/stderr.
    public func openForChild() throws -> FileHandle {
        let directory = (self.path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let fd = open(self.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "Cannot open \(self.path)"])
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Supervisor events in the server's own line format, so a comb of the
    /// log reads one timeline: `2026-09-24 02:40:00 INFO vibepulse-bar: ...`.
    public func append(_ message: String, level: String = "INFO", now: Date = Date()) {
        let line = "\(Self.timestamp(now)) \(level) vibepulse-bar: \(message)\n"
        guard let handle = try? self.openForChild() else { return }
        handle.write(Data(line.utf8))
        try? handle.close()
    }

    public var size: UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: self.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// The last `limit` lines, read from at most the final 64 KiB.
    public func tail(limit: Int = 40) -> [String] {
        Array(self.lines(since: 0).suffix(limit))
    }

    /// The server's own last lines written after `offset`, without the
    /// supervisor's events: what a crash excerpt should show.
    public func serverTail(since offset: UInt64, limit: Int = 12) -> [String] {
        Array(self.lines(since: offset).filter { !$0.contains(" vibepulse-bar: ") }.suffix(limit))
    }

    private func lines(since offset: UInt64) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: self.path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        // The server rotates by truncating in place; below the mark, every
        // remaining byte is newer than the mark.
        let mark = offset <= size ? offset : 0
        let window: UInt64 = 64 * 1024
        let start = max(mark, size > window ? size - window : 0)
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        var lines = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        if start > mark, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

/// Which server process this app owns, persisted so a relaunch after an app
/// crash recognises its own leftover and stops it instead of calling it foreign.
public struct OwnershipRecord: Codable, Equatable, Sendable {
    public var pid: Int32
    public var startTime: TimeInterval
    public var port: Int

    public init(pid: Int32, startTime: TimeInterval, port: Int) {
        self.pid = pid
        self.startTime = startTime
        self.port = port
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VibePulse/vibepulse-bar-service.json")
    }

    public static func load(from url: URL = defaultURL) -> OwnershipRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(OwnershipRecord.self, from: data)
    }

    public func save(to url: URL = defaultURL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func clear(at url: URL = defaultURL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Still the very process that was recorded: same pid AND same kernel start time.
    public var isStillRunning: Bool {
        guard ProcessInspector.isAlive(self.pid),
              let started = ProcessInspector.startTime(of: self.pid)
        else { return false }
        return abs(started - self.startTime) < 1
    }
}
